################################################################################
#
# squid
#
################################################################################

SQUID_VERSION_MAJOR = 3.4
SQUID_VERSION = $(SQUID_VERSION_MAJOR).10
SQUID_SOURCE = squid-$(SQUID_VERSION).tar.xz
SQUID_SITE = http://www.squid-cache.org/Versions/v3/$(SQUID_VERSION_MAJOR)
SQUID_LICENSE = GPLv2+
SQUID_LICENSE_FILES = COPYING
# For squid-01-assume-get-certificate-ok.patch
SQUID_AUTORECONF = YES
SQUID_DEPENDENCIES = libcap host-libcap host-pkgconf \
	$(if $(BR2_PACKAGE_LIBNETFILTER_CONNTRACK),libnetfilter_conntrack)
SQUID_CONF_ENV = \
	ac_cv_epoll_works=yes \
	ac_cv_func_setresuid=yes \
	ac_cv_func_va_copy=yes \
	ac_cv_func___va_copy=yes \
	ac_cv_func_strnstr=no \
	ac_cv_have_squid=yes \
	ACLOCAL="$(ACLOCAL)" \
	AUTOMAKE="$(AUTOMAKE)"
SQUID_CONF_OPTS = \
	--enable-async-io=8 \
	--enable-linux-netfilter \
	--enable-removal-policies="lru,heap" \
	--with-filedescriptors=1024 \
	--disable-ident-lookups \
	--with-krb5-config=no \
	--enable-auth-basic="fake getpwnam" \
	--enable-auth-digest="file" \
	--enable-auth-negotiate="wrapper" \
	--enable-auth-ntlm="fake" \
	--disable-strict-error-checking \
	--enable-external-acl-helpers="file_userip" \
	--with-logdir=/var/log/squid/ \
	--with-pidfile=/var/run/squid.pid \
	--with-swapdir=/var/cache/squid/ \
	--enable-icap-client

# On uClibc librt needs libpthread
ifeq ($(BR2_TOOLCHAIN_HAS_THREADS)$(BR2_TOOLCHAIN_USES_UCLIBC),yy)
	SQUID_CONF_ENV += ac_cv_search_shm_open="-lrt -lpthread"
endif

ifeq ($(BR2_PACKAGE_OPENSSL),y)
	SQUID_CONF_OPTS += --enable-ssl
	SQUID_DEPENDENCIES += openssl
endif

define SQUID_CLEANUP_TARGET
	rm -f $(addprefix $(TARGET_DIR)/usr/bin/, \
		RunCache RunAccel)
	rm -f $(addprefix $(TARGET_DIR)/etc/, \
		cachemgr.conf mime.conf.default squid.conf.default)
endef

SQUID_POST_INSTALL_TARGET_HOOKS += SQUID_CLEANUP_TARGET

$(eval $(autotools-package))
