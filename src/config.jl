# Shared constants for the GMD package (ports the module constants from the
# Python gmd.py and the MATLAB gmdConfig).

const PACKAGE_VERSION = "2.0.0"

const DATA_BASES = [
    "https://gmd-releases.s3.ap-southeast-2.amazonaws.com/data",
    "https://raw.githubusercontent.com/KMueller-Lab/Global-Macro-Database/refs/heads/main/data",
]

const TIMEOUT = 60
const MAX_RETRIES = 3
const BACKOFF_BASE = 0.5
const USER_AGENT = "global-macro-data/$(PACKAGE_VERSION) " *
    "(+https://github.com/KMueller-Lab/Global-Macro-Database-Julia)"

const ID_COLS = ["ISO3", "year", "id", "countryname"]
const ISSUES_URL = "https://github.com/KMueller-Lab/Global-Macro-Database"
const NETWORK_HINT = "If you have active internet access, specify the option: gmd(network=\"yes\")"

const APA_GMD = "Müller, K., Xu, C., Lehbib, M., & Chen, Z. (2025). " *
    "The Global Macro Database: A New International Macroeconomic Dataset " *
    "(NBER Working Paper No. 33714)."
const APA_PACKAGE = "Lehbib, M. & Müller, K. (2025). gmd: The Easy Way to " *
    "Access the World's Most Comprehensive Macroeconomic Database. Working Paper."

const VARS_HINTS = [
    "To print the list of variables: gmd(vars=\"list\")",
    "To load the list of variables: gmd(vars=\"load\")",
]
const COUNTRY_HINTS = [
    "To print the list of countries: gmd(country=\"list\")",
    "To load the list of countries: gmd(country=\"load\")",
]
