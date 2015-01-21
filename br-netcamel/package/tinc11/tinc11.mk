################################################################################
#
# tinc
#
################################################################################

TINC11_VERSION = 1.1pre11
TINC11_SOURCE = tinc-$(TINC11_VERSION).tar.gz
TINC11_SITE = http://www.tinc-vpn.org/packages
TINC11_DEPENDENCIES = lzo openssl zlib
TINC11_LICENSE = GPLv2+ with OpenSSL exception
TINC11_LICENSE_FILES = COPYING COPYING.README
TINC11_CONF_ENV = CFLAGS="$(TARGET_CFLAGS) -std=c99"


ifeq ($(BR2_PACKAGE_READLINE),y)
TINC11_CONF_OPTS += --with-readline=$(STAGING_DIR)
TINC11_DEPENDENCIES += readline
else
TINC11_CONF_OPTS += --disable-readline
endif

$(eval $(autotools-package))
