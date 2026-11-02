#ifndef AUTH_PROTOCOL_H_K4R8DZ2M
#define AUTH_PROTOCOL_H_K4R8DZ2M

#import <Foundation/Foundation.h>

// The interface between OakMate and the privileged helper. Authorization is the external form of an AuthorizationRef which must hold kAuthRightName. Errors are nil on success.

@protocol OakPrivilegedHelper
- (void)prepareWithReply:(void(^)(NSString* error))reply;
- (void)readFileAtPath:(NSString*)path authorization:(NSData*)authorization reply:(void(^)(NSData* content, NSDictionary<NSString*, NSData*>* attributes, NSString* error))reply;
- (void)writeData:(NSData*)content attributes:(NSDictionary<NSString*, NSData*>*)attributes toFileAtPath:(NSString*)path authorization:(NSData*)authorization reply:(void(^)(NSString* error))reply;
- (void)copyFileAtPath:(NSString*)source toPath:(NSString*)destination authorization:(NSData*)authorization reply:(void(^)(NSString* error))reply;
- (void)removeFileAtPath:(NSString*)path authorization:(NSData*)authorization reply:(void(^)(NSString* error))reply;
@end

static inline NSXPCInterface* OakPrivilegedHelperInterface ()
{
	NSXPCInterface* res = [NSXPCInterface interfaceWithProtocol:@protocol(OakPrivilegedHelper)];
	NSSet* attributeClasses = [NSSet setWithObjects:NSDictionary.class, NSString.class, NSData.class, nil];
	[res setClasses:attributeClasses forSelector:@selector(readFileAtPath:authorization:reply:) argumentIndex:1 ofReply:YES];
	[res setClasses:attributeClasses forSelector:@selector(writeData:attributes:toFileAtPath:authorization:reply:) argumentIndex:1 ofReply:NO];
	return res;
}

#endif /* end of include guard: AUTH_PROTOCOL_H_K4R8DZ2M */
