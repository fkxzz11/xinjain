# FakeGPS — Theos tweak
#
# 构建（macOS / Linux + Theos）:
#   export THEOS=$HOME/theos
#   make package FINALPACKAGE=1        # 产出 packages/*.deb（内含 dylib + 过滤 plist）
#   make                               # 只产出 .theos/obj/FakeGPS.dylib
#
# rootless（Dopamine / palera1n 15+）追加: export THEOS_PACKAGE_SCHEME = rootless
# 并把 control 里的 Architecture 改成 iphoneos-arm64

export TARGET = iphone:clang:latest:14.0
export ARCHS  = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FakeGPS

FakeGPS_FILES       = FakeGPSHooks.m FakeGPSAutoAddress.m MapViewController.m HistoryViewController.m
FakeGPS_CFLAGS      = -fobjc-arc -Wno-deprecated-declarations -Wno-objc-method-access
FakeGPS_FRAMEWORKS  = Foundation UIKit CoreLocation MapKit QuartzCore
FakeGPS_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null || true"
