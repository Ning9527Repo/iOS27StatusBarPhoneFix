#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
typedef long NSInteger;typedef double CGFloat;
static unsigned assertions;
#define CHECK(x) do { assertions++;if(!(x)){fprintf(stderr,"check %u failed line %d: %s\n",assertions,__LINE__,#x);abort();} } while(0)
__attribute__((objc_root_class)) @interface PRObject { Class isa; }
+ (id)new; + (Class)class; - (Class)class; - (BOOL)isKindOfClass:(Class)c;
@end
@implementation PRObject
+ (id)new { return class_createInstance(self,0); }
+ (Class)class { return self; }
- (Class)class { return object_getClass(self); }
- (BOOL)isKindOfClass:(Class)c { for(Class x=object_getClass(self);x;x=class_getSuperclass(x))if(x==c)return YES;return NO; }
@end
@interface UIView:PRObject { UIView *_superview,*_window;BOOL _hidden;CGFloat _alpha; }
@property(nonatomic,assign) UIView *superview,*window;
@property(nonatomic) BOOL hidden; @property(nonatomic) CGFloat alpha;
- (void)layoutSubviews;
@end
@implementation UIView
@synthesize superview=_superview,window=_window,hidden=_hidden,alpha=_alpha;
- (void)layoutSubviews {}
@end
@interface UIImageView:UIView { NSInteger _tag;id _image; }
@property(nonatomic) NSInteger tag;@property(nonatomic,assign)id image;
@end
@implementation UIImageView
@synthesize tag=_tag,image=_image;
@end
@interface _UIStatusBarSignalView:UIView @end
@implementation _UIStatusBarSignalView @end
@interface _UIStatusBarWifiSignalView:_UIStatusBarSignalView @end
@implementation _UIStatusBarWifiSignalView @end
@interface PhoneWifiSubclass:_UIStatusBarWifiSignalView @end
@implementation PhoneWifiSubclass @end
@interface _UIStatusBarCellularSignalView:_UIStatusBarSignalView @end
@implementation _UIStatusBarCellularSignalView @end
@interface _UIStatusBarDualCellularSignalView:_UIStatusBarCellularSignalView @end
@implementation _UIStatusBarDualCellularSignalView @end
@interface _UIStatusBarBatteryView:UIView @end
@implementation _UIStatusBarBatteryView @end
@interface FakeWindowView:UIView @end
@implementation FakeWindowView @end
static BOOL fixtureMain=YES;
@interface NSThread:PRObject + (BOOL)isMainThread; @end
@implementation NSThread + (BOOL)isMainThread {return fixtureMain;} @end
static struct {id owner;const void *key;id value;} assocs[64];
static unsigned assocCount;
static id objc_getAssociatedObject(id owner,const void *key) {
 for(unsigned i=0;i<assocCount;i++)if(assocs[i].owner==owner && assocs[i].key==key)return assocs[i].value;
 return nil;
}
static void put(id owner,const void *key,id value) {
 for(unsigned i=0;i<assocCount;i++)if(assocs[i].owner==owner && assocs[i].key==key){assocs[i].value=value;return;}
 assocs[assocCount].owner=owner;assocs[assocCount].key=key;assocs[assocCount++].value=value;
}
typedef void (*PRRenderFunction)(UIView *);
static PRRenderFunction gWifiRender,gCellRender,gDualRender;
static const void *gKeys[4];static unsigned char keys[4];
static BOOL gEnabled=YES,gDraining;
static unsigned long gRefreshCount;
static void PRRefresh(UIView *view);
/* PRODUCTION_HELPERS */
static unsigned wifiCalls,cellCalls,dualCalls;static BOOL throwRender;
static void wifiRender(UIView *view) { wifiCalls++;PRRefresh(view);if(throwRender)@throw [PRObject new]; }
static void cellRender(UIView *view) {cellCalls++;PRRefresh(view);}
static void dualRender(UIView *view) {dualCalls++;PRRefresh(view);}
int main(void) {
 for(unsigned i=0;i<4;i++)gKeys[i]=keys+i;
 gWifiRender=wifiRender;gCellRender=cellRender;gDualRender=dualRender;
 CHECK(PRSignalClass(_UIStatusBarWifiSignalView.class));
 CHECK(PRSignalClass(_UIStatusBarCellularSignalView.class));
 CHECK(PRSignalClass(_UIStatusBarDualCellularSignalView.class));
 CHECK(PRSignalClass(PhoneWifiSubclass.class));
 CHECK(!PRSignalClass(_UIStatusBarBatteryView.class));
 CHECK(!PRSignalClass(FakeWindowView.class));CHECK(!PRSignalClass(UIView.class));
 CHECK(PRWifiView(PhoneWifiSubclass.class));CHECK(!PRCellularView(PhoneWifiSubclass.class));
 CHECK(!PRSignalClass(Nil));
 UIView *window=[UIView new],*cell=[_UIStatusBarCellularSignalView new];cell.window=window;
 UIView *wifi=[PhoneWifiSubclass new];wifi.window=window;
 UIView *dual=[_UIStatusBarDualCellularSignalView new];dual.window=window;
 cell.superview=dual;
 CHECK(PROwner(cell)==dual);CHECK(PROwner(dual)==dual);CHECK(PROwner(wifi)==wifi);
 PRRefresh(wifi);CHECK(wifiCalls==1 && gRefreshCount==1 && !gDraining);
 PRRefresh(cell);CHECK(dualCalls==1 && cellCalls==0);
 cell.superview=nil;PRRefresh(cell);CHECK(cellCalls==1);
 gEnabled=NO;PRRefresh(wifi);gEnabled=YES;CHECK(wifiCalls==1);
 fixtureMain=NO;PRRefresh(wifi);fixtureMain=YES;CHECK(wifiCalls==1);
 wifi.window=nil;PRRefresh(wifi);wifi.window=window;CHECK(wifiCalls==1);
 UIImageView *overlay=[UIImageView new];overlay.tag=0x145a9;overlay.image=[PRObject new];
 overlay.superview=wifi;overlay.hidden=YES;overlay.alpha=0;
 wifi.hidden=YES;wifi.alpha=0.4;put(wifi,gKeys[3],overlay);
 PRRefresh(wifi);CHECK(!overlay.hidden && overlay.alpha==1.0);
 CHECK(wifi.hidden && wifi.alpha==0.4);
 overlay.image=nil;PRRefresh(wifi);CHECK(overlay.hidden);
 overlay.image=[PRObject new];overlay.tag=1;overlay.hidden=YES;overlay.alpha=0;PRRefresh(wifi);
 CHECK(overlay.hidden && overlay.alpha==0);
 overlay.tag=0x145a9;overlay.superview=cell;PRRefresh(wifi);CHECK(overlay.hidden && overlay.alpha==0);
 overlay.superview=wifi;throwRender=YES;
 @try {PRRefresh(wifi);CHECK(0);} @catch(id error){CHECK(error!=nil);}
 CHECK(!gDraining);throwRender=NO;PRRefresh(wifi);CHECK(!gDraining);
 CHECK(!strcmp(PRSkipQualifiers("rnq"),"q"));CHECK(PRSkipQualifiers(NULL)==NULL);
 Method m=class_getInstanceMethod(UIView.class,@selector(layoutSubviews));
 CHECK(PROwnsMethod(UIView.class,method_getName(m)));
 CHECK(!PROwnsMethod(PhoneWifiSubclass.class,method_getName(m)));
 for(unsigned i=0;i<10000;i++){PRRefresh(wifi);PRRefresh(cell);PRRefresh(dual);}
 CHECK(!gDraining && wifiCalls>10000 && cellCalls>10000 && dualCalls>10000);
 printf("{\"assertions\":%u,\"refreshes\":%lu,\"recursive_render_calls\":0,\"uikit\":false}\n",assertions,gRefreshCount);
 return 0;
}
