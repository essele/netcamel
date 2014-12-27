
LUADIR				= /home/essele/dev/opentik/luajit-2.0/src

CFLAGS				= -I$(LUADIR)
LDFLAGS				= -L$(LUADIR)

ALL_D				:= $(wildcard *.d)

%.so:	%.o
	@echo [LD] $@
	@$(CC) -shared -o $@ $^ $(CFLAGS) $(CFLAGS_$@) $(LDFLAGS) $(LDFLAGS_$@) 

%.o:	%.c Makefile
	@echo [CC] $@
	@$(CC) -MD -c -Wall -Werror -fpic -o $@ $(CFLAGS) $(CFLAGS_$(*).c) $<

#
# All of the LIBS we wan to build
#
LIBS				= readline.so

all:				$(LIBS)

clean:
	rm *.o *.so *.d

#
# Special per-file C and LD FLAGS
#
#CFLAGS_mosquitto.c		= -I$(MOSDIR_I) 
#LDFLAGS_mosquitto.so 	= -L$(MOSDIR_L) -lmosquitto -lpthread -lrt

#CFLAGS_netlink.c		= -I/usr/include/libnl3
#LDFLAGS_netlink.so		= -lnl-3 -lnl-route-3

CFLAGS_readline.so		= -ltermcap -lrt

#
# Which objects to each of the libs need...
#
readline.so:			readline.o


include $(ALL_D)

