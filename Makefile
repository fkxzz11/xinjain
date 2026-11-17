# FakeGPS — Theos tweak
#
# 目标设备: iPhone14,6 / iOS 15.6  →  minos 必须 ≤ 15.6（这里用 14.0）
# 构建: make package FINALPACKAGE=1

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
