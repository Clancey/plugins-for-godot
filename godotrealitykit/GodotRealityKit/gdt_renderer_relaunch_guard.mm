//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc.
//
// Licensed under the MIT license (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// LICENSE
//
//===----------------------------------------------------------------------===//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kGDRKRendererRelaunchDetectedNotification = @"GDRKRendererRelaunchDetected";

namespace {

void post_relaunch_detected() {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter]
				postNotificationName:kGDRKRendererRelaunchDetectedNotification
							  object:nil];
	});
}

// The guard is installed from within the first project data setup (Main::setup2),
// so any later call comes from a new GDTRenderer and must not run setup2 again.
bool swizzle_project_data_setup_as_relaunch(Class cls) {
	Method method = class_getInstanceMethod(cls, @selector(setUpProjectDataShowingBootLogo:));
	if (method) {
		method_setImplementation(method, imp_implementationWithBlock(^(id self, BOOL p_show_boot_logo) {
			post_relaunch_detected();
		}));
		return true;
	}

	// Older Godot versions don't take a boot logo argument.
	method = class_getInstanceMethod(cls, @selector(setUpProjectData));
	if (method) {
		method_setImplementation(method, imp_implementationWithBlock(^(id self) {
			post_relaunch_detected();
		}));
		return true;
	}

	NSLog(@"GodotRealityKit: cannot install relaunch guard, missing -[%@ setUpProjectDataShowingBootLogo:] and -[%@ setUpProjectData]",
			NSStringFromClass(cls), NSStringFromClass(cls));
	return false;
}

void swizzle_one_shot_void(Class cls, SEL selector, dispatch_once_t *guard) {
	Method method = class_getInstanceMethod(cls, selector);
	if (!method) {
		NSLog(@"GodotRealityKit: cannot install relaunch guard, missing -[%@ %@]",
				NSStringFromClass(cls), NSStringFromSelector(selector));
		return;
	}

	__block IMP original_imp = method_getImplementation(method);
	IMP guarded_imp = imp_implementationWithBlock(^(id self) {
		dispatch_once(guard, ^{
			((void (*)(id, SEL))original_imp)(self, selector);
		});
	});
	method_setImplementation(method, guarded_imp);
}

} // namespace

namespace gdrk {

void install_renderer_relaunch_guard() {
	static dispatch_once_t install_once;
	dispatch_once(&install_once, ^{
		Class renderer_cls = NSClassFromString(@"GDTRenderer");
		if (!renderer_cls) {
			return;
		}

		swizzle_project_data_setup_as_relaunch(renderer_cls);

		static dispatch_once_t start_guard;
		swizzle_one_shot_void(renderer_cls, @selector(startMain), &start_guard);
	});
}

} // namespace gdrk
