using GMD
using DataFrames
using Test

# Capture everything printed to stdout while running `f`.
function capture(f)
    orig = stdout
    rd, wr = redirect_stdout()
    try
        f()
    finally
        redirect_stdout(orig)
        close(wr)
    end
    return read(rd, String)
end

# Return the GMDCommandError raised by `f` (fails the test if none is).
function caught(f)
    try
        f()
    catch err
        return err
    end
    error("expected a GMDCommandError, none was thrown")
end

const FIXTURES = joinpath(@__DIR__, "fixtures")
const TESTCACHE = joinpath(tempdir(), "gmd_julia_test_cache")

isdir(TESTCACHE) || mkpath(TESTCACHE)
# Route every fetch to the fixtures and keep the real cache untouched.
GMD.use_fixtures(FIXTURES, TESTCACHE)

@testset "GMD" begin

    @testset "argument validation" begin
        out = capture(() -> gmd(print_option="GMD"))
        @test occursin("Global Macro Database", out)
        @test occursin("33714", out)

        out = capture(() -> gmd(print_option="Stata"))
        @test occursin("gmd", out)

        e = caught(() -> gmd(print_option="bogus"))
        @test e isa GMDCommandError && e.code == 198

        @test_throws GMDCommandError gmd(raw="maybe")
        @test_throws GMDCommandError gmd(start_year=2020, end_year=2000)
    end

    @testset "versions" begin
        @test GMD.get_current_version() == "2025_12"
        v = GMD.get_available_versions()
        @test v[1] == "2025_12"
        @test length(v) == 3

        @test occursin("2025_12", capture(() -> gmd(version="list")))
        @test occursin("Current version: 2025_12", capture(() -> gmd(version="current")))
        @test_throws GMDCommandError gmd(version="1900_01")
    end

    @testset "vars" begin
        out = capture(() -> gmd(vars="list"))
        @test occursin("Available variables", out)
        @test occursin("rGDP", out)

        t = gmd(vars="load")
        @test t isa DataFrame
        @test nrow(t) > 0
    end

    @testset "cite" begin
        @test occursin("@techreport", capture(() -> gmd(cite="GMD")))
        @test_throws GMDCommandError gmd(cite="NOPE")
        @test_throws GMDCommandError gmd(cite="GMD IMF_WEO")
        @test gmd(cite="load") isa DataFrame
    end

    @testset "sources" begin
        @test occursin("IMF_WEO", capture(() -> gmd(sources="list")))

        t = gmd(sources="load")
        @test t isa DataFrame && nrow(t) > 0

        df = gmd(sources="IMF_IFS")
        @test df isa DataFrame
        @test all(c -> c in names(df), ("ISO3", "year"))

        df = gmd(sources="IMF_IFS", variables="CA_USD")
        @test "IMF_IFS_CA_USD" in names(df)

        # CS1_ARG normalizes to source ARG_1 with columns prefixed CS1_.
        df = gmd(sources="CS1_ARG", variables="M3_GDP")
        @test "CS1_M3_GDP" in names(df)

        # Two-digit slots and lower case: CS10_ITA loads ITA_10, columns CS10_.
        for name in ("CS10_ITA", "cs10_ita", "ITA_10")
            df = gmd(sources=name)
            @test "CS10_CPI" in names(df)
            @test maximum(Int.(df.year)) == 1913
        end
        df = gmd(sources="cs10_ita", variables="CPI")
        @test names(df) == ["ISO3", "year", "CS10_CPI"]
        e = caught(() -> gmd(sources="CS10_ITA", variables="M3"))
        @test e isa GMDCommandError && occursin("It has data on CPI nGDP rGDP.", e.msg)

        @test_throws GMDCommandError gmd(sources="NOPE")
    end

    @testset "source name aliases" begin
        @test GMD.normalize_source_name("CS1_ARG") == "ARG_1"
        @test GMD.normalize_source_name("CS10_ITA") == "ITA_10"
        @test GMD.normalize_source_name("cs10_ita") == "ITA_10"
        @test GMD.normalize_source_name(" CS123_usa ") == "USA_123"
        for name in ("IMF_WEO", "AAL", "CatSol", "Mitchell", "BoCBoE", "CEPII",
                     "ITA_10", "ARG_1", "CS1", "CS_ARG", "CS1_ARGX", "CSX_ARG")
            @test GMD.normalize_source_name(name) == name
        end

        @test GMD.cs_column_prefix("CS1_ARG") == "CS1"
        @test GMD.cs_column_prefix("cs10_ita") == "CS10"
        @test GMD.cs_column_prefix("ITA_10") == ""
        @test GMD.cs_column_prefix("IMF_WEO") == ""
    end

    @testset "default load" begin
        df = gmd()
        @test df isa DataFrame
        @test sort(unique(string.(df.ISO3))) == ["CHN", "DEU", "USA"]
    end

    @testset "variable selection" begin
        df = gmd(variables="rgdp")
        @test "rGDP" in names(df)
        @test !("rgdp" in names(df))
        @test "ISO3" in names(df)

        @test_throws GMDCommandError gmd(variables="bogus")
    end

    @testset "country filter" begin
        df = gmd(country="USA", variables="rGDP")
        @test unique(string.(df.ISO3)) == ["USA"]

        df = gmd(country=["USA", "DEU"], variables="rGDP")
        @test sort(unique(string.(df.ISO3))) == ["DEU", "USA"]

        @test_throws GMDCommandError gmd(country="ZZZ", variables="rGDP")
    end

    @testset "year handling" begin
        # USA 1999 has no rGDP/infl, so the cumulative trim drops it.
        df = gmd(country="USA", variables=["rGDP", "infl"])
        years = Int.(df.year)
        @test !(1999 in years)
        @test minimum(years) == 2000

        df = gmd(variables="rGDP", start_year=2001, end_year=2002)
        years = Int.(df.year)
        @test minimum(years) >= 2001
        @test maximum(years) <= 2002
    end

    @testset "raw" begin
        df = gmd(variables="rGDP", raw=true)
        @test df isa DataFrame
        @test "rGDP" in names(df)

        @test_throws GMDCommandError gmd(variables=["rGDP", "infl"], raw=true)
    end

    @testset "country list/load" begin
        out = capture(() -> gmd(country="list"))
        @test occursin("Available countries", out)
        @test occursin("ARG", out)

        t = gmd(country="load")
        @test nrow(t) == 10
        @test all(c -> c in names(t), ("ISO3", "countryname"))

        @test occursin("Available countries", capture(() -> gmd(iso=true)))
    end

end

GMD.reset_backend()
