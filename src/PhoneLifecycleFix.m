// Ning&半生年华&yaowell&Benja Guo
// Companion for the verified 1.2-1 binary. No replacement artwork or geometry.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <CommonCrypto/CommonDigest.h>
#import <ptrauth.h>
#import <stdatomic.h>
#import <string.h>
#import <stdlib.h>
#import "VendorMap.h"

typedef void (*PRRenderFunction)(UIView *);
static PRRenderFunction gWifiRender, gCellRender, gDualRender;
static const void *gKeys[4], *gColorKey;
static NSMutableSet<NSString *> *gInstalled;
static NSHashTable<UIView *> *gDirty;
static NSArray *gObservers;
static BOOL gEnabled, gDraining, gDiscoveryQueued, gDrainQueued;
static unsigned gCallDepth;
static _Atomic(bool) gImageCheckQueued;
static unsigned long gRefreshCount, gHookCount;
static void PRRefresh(UIView *view);
static void PRDrain(void);
static void PRDiscover(void);
static void PRCheckImages(void);

static BOOL PRNameContains(Class cls, const char *part) {
    for (Class c=cls; c; c=class_getSuperclass(c)) {
        const char *name=class_getName(c);
        if (name && strstr(name,part)) return YES;
    }
    return NO;
}
static BOOL PRStatusView(Class cls) {
    if(!cls) return NO;
    BOOL isView=NO;
    for(Class c=cls;c;c=class_getSuperclass(c)) if(c==UIView.class){isView=YES;break;}
    // Match the vendor's phone and Control Center families: the CC signal
    // classes need not carry "StatusBar" in their concrete name.
    return isView && (PRNameContains(cls,"StatusBar") || PRNameContains(cls,"Signal"));
}
static BOOL PRWifiView(Class cls) {
    return PRStatusView(cls) && (PRNameContains(cls,"WifiSignal") || PRNameContains(cls,"WiFiSignal"));
}
static BOOL PRCellularView(Class cls) {
    // The phone CC family may be named only *Signal* rather than *Cellular*;
    // follow the vendor's own StatusBar/Signal discovery rule for non-Wi-Fi.
    return PRStatusView(cls) && !PRWifiView(cls) && PRNameContains(cls,"Signal");
}
static BOOL PRSignalClass(Class cls) { return PRCellularView(cls)||PRWifiView(cls); }
static BOOL PRVisibleColor(id color) {
    return [color isKindOfClass:UIColor.class] && CGColorGetAlpha(((UIColor *)color).CGColor)>0.01;
}
static void PRCacheColor(UIView *view, SEL sel, id color) {
    if (gEnabled && gColorKey && sel==@selector(setActiveColor:) && PRVisibleColor(color))
        objc_setAssociatedObject(view,gColorKey,color,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void PRRepairOwnedOverlays(UIView *owner) {
    static const NSInteger tags[4]={0x1ae9a,0x1ae9b,0x1ae9c,0x145a9};
    for(unsigned i=0;i<4;i++) {
        id value=objc_getAssociatedObject(owner,gKeys[i]);
        if(![value isKindOfClass:UIImageView.class]) continue;
        UIImageView *image=value;
        if(image.tag!=tags[i] || image.superview!=owner) continue;
        // Only the vendor-owned image, never the signal host/window/ancestors.
        image.hidden=(image.image==nil);
        if(image.image) image.alpha=1.0;
    }
}
static UIView *PROwner(UIView *view) {
    if(PRWifiView(object_getClass(view))) return view;
    for(UIView *parent=view;parent;parent=parent.superview)
        if(PRNameContains(object_getClass(parent),"DualCellularSignal")) return parent;
    return view;
}
static void PRRefresh(UIView *view) {
    if(!gEnabled || !gWifiRender || !gCellRender || !gDualRender ||
       ![NSThread isMainThread] || !view.window ||
       !PRSignalClass(object_getClass(view))) return;
    // Reuse only pure original renderers. The original dispatcher can schedule
    // a whole-window re-scan and re-run the vendor's 64-slot hook installer.
    if(gDraining) return;
    gDraining=YES;
    @try {
        UIView *owner=PROwner(view);
        if(PRWifiView(object_getClass(owner))) gWifiRender(owner);
        else if(PRNameContains(object_getClass(owner),"DualCellularSignal")) gDualRender(owner);
        else gCellRender(owner);
        PRRepairOwnedOverlays(owner); gRefreshCount++;
    } @finally { gDraining=NO; }
}
static void PRDirty(UIView *view) {
    if(!gEnabled || !view || !PRSignalClass(object_getClass(view))) return;
    if(![NSThread isMainThread]) {
        __weak UIView *weakView=view;
        dispatch_async(dispatch_get_main_queue(),^{ PRRefresh(weakView); });
        return;
    }
    if(gDraining) return;
    [gDirty addObject:view];
    if(!gCallDepth) {
        if(gDrainQueued) return;
        gDrainQueued=YES;
        dispatch_async(dispatch_get_main_queue(),^{gDrainQueued=NO;PRDrain();});
    }
}
static void PRDrain(void) {
    if(gCallDepth || gDraining || !gDirty.count) return;
    NSArray *views=gDirty.allObjects;
    [gDirty removeAllObjects];
    for(UIView *view in views) PRRefresh(view);
}

// A captured original IMP is called directly, never redispatched by selector.
// If the vendor later wraps this method, its new wrapper captures us once;
// we do not reinstall and cannot capture that new wrapper back into a cycle.
static BOOL PROwnsMethod(Class cls, SEL sel) {
    unsigned count=0;Method *methods=class_copyMethodList(cls,&count);BOOL found=NO;
    for(unsigned i=0;i<count;i++) if(method_getName(methods[i])==sel){found=YES;break;}
    free(methods);return found;
}
static const char *PRSkipQualifiers(const char *type) {
    while(type && *type && strchr("rnNoORV",*type)) type++;
    return type;
}
static void PRHook(Class cls, SEL sel, unsigned kind) {
    NSString *key=[NSString stringWithFormat:@"%p/%s",cls,sel_getName(sel)];
    if([gInstalled containsObject:key]) return;
    // Inherited implementations already pass through the nearest parent hook.
    if(!PROwnsMethod(cls,sel) && PRSignalClass(class_getSuperclass(cls))) return;
    Method method=class_getInstanceMethod(cls,sel);if(!method)return;
    unsigned argc=method_getNumberOfArguments(method);
    char *ret=method_copyReturnType(method);
    BOOL valid=ret && !strcmp(PRSkipQualifiers(ret),"v") && argc==(kind?3u:2u);
    free(ret);if(!valid)return;
    char *arg=kind?method_copyArgumentType(method,2):NULL;
    const char *type=PRSkipQualifiers(arg);
    char valueType=type?*type:0;
    if(kind==1 && valueType!='@'){free(arg);return;}
    if(kind==2 && (!valueType || !strchr("qiIlLQ",valueType))){free(arg);return;}
    if(kind==3 && valueType!='B' && valueType!='c'){free(arg);return;}
    if(kind==4 && valueType!='d'){free(arg);return;}
    free(arg);
    IMP original=method_getImplementation(method);if(!original)return;
    IMP replacement=NULL;
    if(kind==0) {
        replacement=imp_implementationWithBlock(^(UIView *view){
            BOOL main=[NSThread isMainThread];if(main)gCallDepth++;
            @try { ((void(*)(id,SEL))original)(view,sel); }
            @finally { if(main)gCallDepth--; }
            PRDirty(view);
        });
    } else if(kind==1) {
        replacement=imp_implementationWithBlock(^(UIView *view,id value){
            BOOL main=[NSThread isMainThread];if(main){gCallDepth++;PRCacheColor(view,sel,value);}
            @try { ((void(*)(id,SEL,id))original)(view,sel,value); }
            @finally { if(main)gCallDepth--; }
            PRDirty(view);
        });
    } else if(kind==3) {
        replacement=imp_implementationWithBlock(^(UIView *view,BOOL value){
            BOOL main=[NSThread isMainThread];if(main)gCallDepth++;
            @try { ((void(*)(id,SEL,BOOL))original)(view,sel,value); }
            @finally { if(main)gCallDepth--; }
            PRDirty(view);
        });
    } else if(kind==4) {
        replacement=imp_implementationWithBlock(^(UIView *view,CGFloat value){
            BOOL main=[NSThread isMainThread];if(main)gCallDepth++;
            @try { ((void(*)(id,SEL,CGFloat))original)(view,sel,value); }
            @finally { if(main)gCallDepth--; }
            PRDirty(view);
        });
    } else if(valueType=='i' || valueType=='I') {
        replacement=imp_implementationWithBlock(^(UIView *view,int value){
            BOOL main=[NSThread isMainThread];if(main)gCallDepth++;
            @try { ((void(*)(id,SEL,int))original)(view,sel,value); }
            @finally { if(main)gCallDepth--; }
            PRDirty(view);
        });
    } else {
        replacement=imp_implementationWithBlock(^(UIView *view,NSInteger value){
            BOOL main=[NSThread isMainThread];if(main)gCallDepth++;
            @try { ((void(*)(id,SEL,NSInteger))original)(view,sel,value); }
            @finally { if(main)gCallDepth--; }
            PRDirty(view);
        });
    }
    if(!replacement)return;
    // Add first, so an inherited Method is never modified on UIView.
    if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(method))) {
        if(!PROwnsMethod(cls,sel)){imp_removeBlock(replacement);return;}
        method_setImplementation(class_getInstanceMethod(cls,sel),replacement);
    }
    [gInstalled addObject:key];gHookCount++;
}

static void PRHookClasses(void) {
    // Materialize lifecycle hooks on UIView itself as a discovery backstop.
    // The wrapper is filtered by PRDirty, so ordinary UIKit views are untouched
    // beyond one cheap class-name check and the original IMP call.
    PRHook(UIView.class,@selector(didMoveToWindow),0);
    PRHook(UIView.class,@selector(didMoveToSuperview),0);
    PRHook(UIView.class,@selector(layoutSubviews),0);
    unsigned count=0;Class *classes=objc_copyClassList(&count);
    NSMutableArray *targets=[NSMutableArray array];
    for(unsigned i=0;i<count;i++) if(PRSignalClass(classes[i])) [targets addObject:classes[i]];
    free(classes);
    [targets sortUsingComparator:^NSComparisonResult(Class a,Class b){
        unsigned da=0,db=0;
        for(Class c=a;c;c=class_getSuperclass(c))da++;
        for(Class c=b;c;c=class_getSuperclass(c))db++;
        return da<db?NSOrderedAscending:da>db?NSOrderedDescending:NSOrderedSame;
    }];
    for(Class cls in targets) {
        PRHook(cls,@selector(layoutSubviews),0);
        PRHook(cls,@selector(didMoveToWindow),0);
        PRHook(cls,@selector(didMoveToSuperview),0);
        PRHook(cls,@selector(setHidden:),3);
        PRHook(cls,@selector(setAlpha:),4);
        PRHook(cls,NSSelectorFromString(@"_updateActiveBars"),0);
        PRHook(cls,NSSelectorFromString(@"setNumberOfActiveBars:"),2);
        PRHook(cls,NSSelectorFromString(@"setActiveColor:"),1);
        PRHook(cls,NSSelectorFromString(@"setInactiveColor:"),1);
        PRHook(cls,@selector(traitCollectionDidChange:),1);
    }
}
static void PRWalk(UIView *view,unsigned depth,unsigned *visited) {
    if(!view || depth>40 || ++(*visited)>20000)return;
    if(PRSignalClass(object_getClass(view))) PRDirty(view);
    // Finite, notification-driven walk; never from every UIView layout.
    for(UIView *child in [view.subviews copy]) PRWalk(child,depth+1,visited);
}
static void PRDiscover(void) {
    if(!gEnabled || ![NSThread isMainThread])return;
    PRHookClasses();
    NSMutableSet *windows=[NSMutableSet set];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if([scene isKindOfClass:UIWindowScene.class])
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    unsigned visited=0;
    for(UIWindow *window in windows) PRWalk(window,0,&visited);
}
static void PRQueueDiscovery(void) {
    if(gDiscoveryQueued)return;
    gDiscoveryQueued=YES;
    dispatch_async(dispatch_get_main_queue(),^{gDiscoveryQueued=NO;PRDiscover();});
}
static PRRenderFunction PRFunction(const struct mach_header_64 *header,uintptr_t va) {
    return (PRRenderFunction)ptrauth_sign_unauthenticated(
        (void *)((uintptr_t)header+va),ptrauth_key_function_pointer,0);
}
static void PRActivate(const struct mach_header_64 *header,intptr_t slide,const PRVendorMap *map) {
    gWifiRender=PRFunction(header,map->wifi);
    gCellRender=PRFunction(header,map->cell);
    gDualRender=PRFunction(header,map->dual);
    for(unsigned i=0;i<4;i++) gKeys[i]=(const void *)((uintptr_t)header+map->keys[i]);
    gColorKey=(const void *)((uintptr_t)header+map->colorKey);
    (void)slide; // __TEXT.vmaddr == 0 checked before using header-relative VAs.
    gInstalled=[NSMutableSet set];gDirty=[NSHashTable weakObjectsHashTable];gEnabled=YES;
    NSMutableArray *tokens=[NSMutableArray array];
    for(NSString *name in @[UIWindowDidBecomeVisibleNotification,
          UIApplicationDidBecomeActiveNotification,UISceneDidActivateNotification]) {
        id token=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){ PRQueueDiscovery(); }];
        [tokens addObject:token];
    }
    gObservers=tokens;
    PRDiscover();
    NSLog(@"[StatusBar27PhoneFix] activated verified vendor; hooks=%lu",gHookCount);
}
static void PRCheckImages(void) {
    if(![NSThread isMainThread])return;
    if(gEnabled){PRDiscover();return;}
    for(uint32_t index=0;index<_dyld_image_count();index++) {
        const char *name=_dyld_get_image_name(index);
        if(!name || !strstr(name,"/iOS27StatusBar.dylib"))continue;
        const struct mach_header_64 *h=(const void *)_dyld_get_image_header(index);
        if(!h || h->magic!=MH_MAGIC_64 || h->cputype!=CPU_TYPE_ARM64 || h->sizeofcmds>65536)continue;
        const struct uuid_command *uuid=NULL;const struct section_64 *text=NULL;
        const struct segment_command_64 *segment=NULL;
        uintptr_t p=(uintptr_t)(h+1),end=p+h->sizeofcmds;BOOL valid=YES;
        for(uint32_t i=0;i<h->ncmds;i++) {
            if(p+sizeof(struct load_command)>end){valid=NO;break;}
            const struct load_command *lc=(const void *)p;
            if(lc->cmdsize<sizeof(*lc) || p+lc->cmdsize>end){valid=NO;break;}
            if(lc->cmd==LC_UUID && lc->cmdsize==sizeof(struct uuid_command))uuid=(const void *)p;
            if(lc->cmd==LC_SEGMENT_64 && lc->cmdsize>=sizeof(struct segment_command_64)) {
                const struct segment_command_64 *sg=(const void *)p;
                if(!strncmp(sg->segname,"__TEXT",16)) {
                    segment=sg;
                    if(sg->nsects>(lc->cmdsize-sizeof(*sg))/sizeof(struct section_64)){valid=NO;break;}
                    const struct section_64 *sections=(const void *)(sg+1);
                    for(uint32_t j=0;j<sg->nsects;j++)
                        if(!strncmp(sections[j].sectname,"__text",16))text=sections+j;
                }
            }
            p+=lc->cmdsize;
        }
        if(!valid || !uuid || !text || !segment || segment->vmaddr || segment->fileoff ||
           !text->size || text->size>UINT32_MAX || text->addr>segment->vmsize ||
           text->size>segment->vmsize-text->addr)continue;
        for(unsigned i=0;i<sizeof(kPRVendorMaps)/sizeof(kPRVendorMaps[0]);i++) {
            const PRVendorMap *map=&kPRVendorMaps[i];
            if(memcmp(uuid->uuid,map->uuid,16) || text->addr!=map->textVA || text->size!=map->textSize)continue;
            uint8_t digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256((const void *)((uintptr_t)h+text->addr),(CC_LONG)text->size,digest);
            if(memcmp(digest,map->textSHA256,sizeof digest))continue;
            PRActivate(h,_dyld_get_image_vmaddr_slide(index),map);return;
        }
    }
}
static void PRImageAdded(__unused const struct mach_header *header,__unused intptr_t slide) {
    // dyld may hold its loader lock. Never touch Objective-C or install there.
    if(atomic_exchange_explicit(&gImageCheckQueued,true,memory_order_relaxed))return;
    dispatch_async(dispatch_get_main_queue(),^{
        atomic_store_explicit(&gImageCheckQueued,false,memory_order_relaxed);
        PRCheckImages();
    });
}
__attribute__((constructor)) static void PRLoad(void) {
    @autoreleasepool {
        if(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"])return;
        _dyld_register_func_for_add_image(PRImageAdded);
        dispatch_async(dispatch_get_main_queue(), ^{ PRCheckImages(); });
    }
}
