HOMEPAGE = "https://github.com/theskumar/python-dotenv"
SUMMARY = "Python Dot Env Handler"
DESCRIPTION = "Shell Command and Library to write and read .env like files."
SECTION = "devel/python"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=e914cdb773ae44a732b392532d88f072"

PYPI_PACKAGE = "python_dotenv"
UPSTREAM_CHECK_PYPI_PACKAGE = "${PYPI_PACKAGE}"

SRC_URI[sha256sum] = "2c371a91fbd7ba082c2c1dc1f8bf89ca22564a087c2c287cd9b662adde799cf3"

inherit pypi python_setuptools_build_meta

CVE_PRODUCT = "saurabh-kumar:python-dotenv theskumar:python-dotenv"
