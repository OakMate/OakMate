// Launch daemon that reads and writes files on behalf of OakMate. It is registered with SMAppService from OakMate.app/Contents/Library/LaunchDaemons and runs as root.
//
// Connections are only accepted from the copy of OakMate that contains this helper, and every request must carry an authorization that holds kAuthRightName, which requires the user to authenticate as an administrator.

#import <authorization/constants.h>
#import <authorization/protocol.h>
#import <io/path.h>
#import <copyfile.h>
#import <os/log.h>

static os_log_t const kLog = os_log_create(kPrivilegedHelperLabel, "helper");

// ==================
// = Authorization =
// ==================

static NSString* install_right ()
{
	NSDictionary* definition = @{
		@"class":      @"user",
		@"group":      @"admin",
		@"allow-root": @NO, // The helper itself runs as root and must not be granted the right on its own
		@"shared":     @NO,
		@"timeout":    @300,
	};

	CFDictionaryRef current = nullptr;
	if(AuthorizationRightGet(kAuthRightName, &current) == errAuthorizationSuccess)
	{
		NSDictionary* dict = CFBridgingRelease(current);
		if([[dict dictionaryWithValuesForKeys:definition.allKeys] isEqualToDictionary:definition])
			return nil;
	}

	AuthorizationRef authRef;
	OSStatus status = AuthorizationCreate(nullptr, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authRef);
	if(status == errAuthorizationSuccess)
	{
		status = AuthorizationRightSet(authRef, kAuthRightName, (__bridge CFDictionaryRef)definition, nullptr, nullptr, nullptr);
		AuthorizationFree(authRef, kAuthorizationFlagDefaults);
	}
	return status == errAuthorizationSuccess ? nil : [NSString stringWithFormat:@"Unable to define the authorization right ‘%s’: %d", kAuthRightName, (int)status];
}

static bool is_authorized (NSData* externalForm)
{
	if(externalForm.length != sizeof(AuthorizationExternalForm))
		return false;

	AuthorizationRef authRef;
	if(AuthorizationCreateFromExternalForm((AuthorizationExternalForm const*)externalForm.bytes, &authRef) != errAuthorizationSuccess)
		return false;

	// Without kAuthorizationFlagInteractionAllowed this succeeds only when the user has already authenticated in OakMate
	AuthorizationItem items[]        = { { kAuthRightName, 0, nullptr, 0 } };
	AuthorizationRights const rights = { 1, items };
	OSStatus status = AuthorizationCopyRights(authRef, &rights, kAuthorizationEmptyEnvironment, kAuthorizationFlagExtendRights, nullptr);
	AuthorizationFree(authRef, kAuthorizationFlagDefaults);
	return status == errAuthorizationSuccess;
}

// Only OakMate.app containing this helper (at Contents/MacOS) may connect. For ad-hoc signed builds its designated requirement is the code directory hash.
static NSString* client_requirement ()
{
	NSURL* app = NSBundle.mainBundle.executableURL.URLByResolvingSymlinksInPath.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
	if(![app.pathExtension isEqualToString:@"app"])
		return nil;

	NSString* res = nil;
	SecStaticCodeRef code = nullptr;
	SecRequirementRef requirement = nullptr;
	CFStringRef str = nullptr;
	if(SecStaticCodeCreateWithPath((__bridge CFURLRef)app, kSecCSDefaultFlags, &code) == errSecSuccess && SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &requirement) == errSecSuccess && SecRequirementCopyString(requirement, kSecCSDefaultFlags, &str) == errSecSuccess)
		res = CFBridgingRelease(str);

	if(requirement)
		CFRelease(requirement);
	if(code)
		CFRelease(code);
	return res;
}

// ===========================================
// = Removal of auth_server from OakMate 2.1 =
// ===========================================

static void remove_legacy_helper ()
{
	char const* plist = "/Library/LaunchDaemons/com.isztld.oakmate.auth_server.plist";
	if(access(plist, F_OK) == 0)
	{
		NSTask* task = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/bin/launchctl"] arguments:@[ @"bootout", @"system", @(plist) ] error:nil terminationHandler:nil];
		[task waitUntilExit];
		unlink(plist);
	}

	unlink("/Library/PrivilegedHelperTools/com.isztld.oakmate.auth_server");
	unlink("/var/run/com.isztld.oakmate.auth_server.sock");

	char const* legacyRight = "com.isztld.oakmate.openfile";
	if(AuthorizationRightGet(legacyRight, nullptr) == errAuthorizationSuccess)
	{
		AuthorizationRef authRef;
		if(AuthorizationCreate(nullptr, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authRef) == errAuthorizationSuccess)
		{
			AuthorizationRightRemove(authRef, legacyRight);
			AuthorizationFree(authRef, kAuthorizationFlagDefaults);
		}
	}
}

// ============
// = Requests =
// ============

static NSString* const kNotAuthorized = @"Not authorized.";

static NSString* error_message (char const* action, NSString* path)
{
	return [NSString stringWithFormat:@"%s “%@”: %s", action, path, strerror(errno)];
}

@interface OakPrivilegedHelperService : NSObject <OakPrivilegedHelper>
@end

@implementation OakPrivilegedHelperService
- (void)prepareWithReply:(void(^)(NSString*))reply
{
	reply(install_right());
}

- (void)readFileAtPath:(NSString*)path authorization:(NSData*)authorization reply:(void(^)(NSData*, NSDictionary<NSString*, NSData*>*, NSString*))reply
{
	if(!is_authorized(authorization))
		return reply(nil, nil, kNotAuthorized);
	if(!path.isAbsolutePath)
		return reply(nil, nil, @"Path must be absolute.");

	std::string const content = path::content(path.fileSystemRepresentation);
	if(content == NULL_STR)
		return reply(nil, nil, error_message("Reading", path));

	NSMutableDictionary* attributes = [NSMutableDictionary dictionary];
	for(auto const& pair : path::attributes(path.fileSystemRepresentation))
		attributes[@(pair.first.c_str())] = [NSData dataWithBytes:pair.second.data() length:pair.second.size()];

	reply([NSData dataWithBytes:content.data() length:content.size()], attributes, nil);
}

- (void)writeData:(NSData*)content attributes:(NSDictionary<NSString*, NSData*>*)attributes toFileAtPath:(NSString*)path authorization:(NSData*)authorization reply:(void(^)(NSString*))reply
{
	if(!is_authorized(authorization))
		return reply(kNotAuthorized);
	if(!path.isAbsolutePath)
		return reply(@"Path must be absolute.");

	std::map<std::string, std::string> map;
	for(NSString* key in attributes)
		map.emplace(key.UTF8String, std::string((char const*)attributes[key].bytes, attributes[key].length));

	char const* bytes = (char const*)content.bytes;
	if(!path::set_content(path.fileSystemRepresentation, bytes, bytes + content.length))
		return reply(error_message("Writing", path));
	if(!path::set_attributes(path.fileSystemRepresentation, map))
		return reply(error_message("Setting extended attributes of", path));
	reply(nil);
}

- (void)copyFileAtPath:(NSString*)source toPath:(NSString*)destination authorization:(NSData*)authorization reply:(void(^)(NSString*))reply
{
	if(!is_authorized(authorization))
		return reply(kNotAuthorized);
	if(!source.isAbsolutePath || !destination.isAbsolutePath)
		return reply(@"Paths must be absolute.");

	if(!path::make_dir(path::parent(destination.fileSystemRepresentation)))
		return reply(error_message("Creating parent folder of", destination));

	struct stat buf;
	if(lstat(destination.fileSystemRepresentation, &buf) == 0 && !S_ISREG(buf.st_mode) && unlink(destination.fileSystemRepresentation) != 0)
		return reply(error_message("Removing", destination));

	if(copyfile(source.fileSystemRepresentation, destination.fileSystemRepresentation, nullptr, COPYFILE_ALL|COPYFILE_NOFOLLOW_SRC) != 0)
		return reply(error_message("Copying to", destination));
	reply(nil);
}

- (void)removeFileAtPath:(NSString*)path authorization:(NSData*)authorization reply:(void(^)(NSString*))reply
{
	if(!is_authorized(authorization))
		return reply(kNotAuthorized);
	if(!path.isAbsolutePath)
		return reply(@"Path must be absolute.");

	struct stat buf;
	if(lstat(path.fileSystemRepresentation, &buf) == 0 && S_ISDIR(buf.st_mode))
		return reply(@"Removing folders is not supported.");
	if(unlink(path.fileSystemRepresentation) != 0 && errno != ENOENT)
		return reply(error_message("Removing", path));
	reply(nil);
}
@end

// ============
// = Listener =
// ============

@interface OakPrivilegedHelperListener : NSObject <NSXPCListenerDelegate>
@end

@implementation OakPrivilegedHelperListener
- (BOOL)listener:(NSXPCListener*)listener shouldAcceptNewConnection:(NSXPCConnection*)connection
{
	NSString* requirement = client_requirement();
	if(!requirement)
	{
		os_log_error(kLog, "Unable to obtain the code signing requirement of OakMate");
		return NO;
	}

	[connection setCodeSigningRequirement:requirement];
	connection.exportedInterface = OakPrivilegedHelperInterface();
	connection.exportedObject    = [[OakPrivilegedHelperService alloc] init];
	[connection resume];
	return YES;
}
@end

int main (int argc, char const* argv[])
{
	if(geteuid() != 0)
	{
		fprintf(stderr, "%s: must be run by launchd as root\n", getprogname());
		return EX_NOPERM;
	}

	@autoreleasepool {
		remove_legacy_helper();
		if(NSString* error = install_right())
			os_log_error(kLog, "%{public}@", error);

		static OakPrivilegedHelperListener* delegate = [[OakPrivilegedHelperListener alloc] init];
		NSXPCListener* listener = [[NSXPCListener alloc] initWithMachServiceName:@kPrivilegedHelperLabel];
		listener.delegate = delegate;
		[listener resume];
	}

	dispatch_main();
}
