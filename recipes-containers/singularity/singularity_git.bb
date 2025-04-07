# Skip QA check for library symbolic links (core issue is a packaging problem within
# Singularity build / config: read up on the dev-so test for more info)
INSANE_SKIP:${PN} += "dev-so"

RDEPENDS:${PN} += "python3 ca-certificates openssl bash e2fsprogs-mke2fs"

LICENSE = "BSD-3-Clause | Apache-2.0"
LIC_FILES_CHKSUM = "file://COPYRIGHT.md;md5=ed21b60743b305a734f53029f37d94fc \
                    file://LICENSE-LBNL.md;md5=5f7c53093a01a7b1495d80b29cb72e35 \
                    file://LICENSE.md;md5=fdcf58cf8020ccdfad7f67cd64c61624 \
                   "

SRC_URI = "git://github.com/singularityware/singularity.git;protocol=https;branch=master \
"
PV = "v3.8.3+git"
SRCREV = "9dceb4240c12b4cff1da94630d422a3422b39fcf"

GO_IMPORT = "import"

inherit python3native
inherit go goarch
inherit pkgconfig

S = "${WORKDIR}/git"
B = "${S}"

# EXTRA_OECONF = "--prefix=/usr/local"

do_configure() {
    echo "configure"
    echo "source dir: ${S}"
    echo "build dir: ${B}"
    echo "working directory: "
    pwd
    ./mconfig
    ls -alF
    # exit 1
}
do_compile() {
    echo "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"

    cd builddir
    oe_runmake singularity

    pwd
    exit 1
}

pkg_postinst:${PN}() {
    # python3 expects CA certificates to be installed in a different place to where
    # they are actually installed. These lines link the two locations.
    rm -r $D${libdir}/ssl/certs
    ln -sr $D${sysconfdir}/ssl/certs $D${libdir}/ssl
}
