# FakeGPS — Theos tweak（与原版二进制同规格：minos 16.5 / arm64e）
#
# 对齐原始 FakeGPS.dylib 的构建参数：
#   原始: platform=iOS minos=16.5.0 sdk=16.4/16.5, 切片 arm64 + arm64e（App 内为 arm64e）
#   这里只出 arm64e，避免注入工具/进程架构不匹配导致的 "wrong architecture" 秒退
#
# 构建: make package FINALPACKAGE=1

export TARGET = iphone:clang:latest:16.5
export ARCHS  = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FakeGPS

FakeGPS_FILES       = FakeGPSHooks.m FakeGPSAutoAddress.m MapViewController.m HistoryViewController.m
FakeGPS_CFLAGS      = -fobjc-arc -Wno-deprecated-declarations -Wno-objc-method-access
FakeGPS_FRAMEWORKS  = Foundation UIKit CoreLocation MapKit QuartzCore
FakeGPS_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null || true"
