VERSION ?= 1.3.0
DIST = dist

.PHONY: all test deb macos-tar clean

all: test deb macos-tar

test:
	bash ocvpn-tests.sh

deb:
	bash packaging/debian/build.sh $(VERSION)

macos-tar:
	bash packaging/macos/build-tar.sh $(VERSION)

clean:
	rm -rf $(DIST) /tmp/ocvpn-deb-* /tmp/ocvpn-mac-* /tmp/ocvpn-pkg-*
