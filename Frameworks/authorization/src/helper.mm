#import "helper.h"
#import "constants.h"
#import "protocol.h"
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>

// ===================
// = authorization_t =
// ===================

namespace osx
{
	bool authorization_t::obtain_right (char const* right, std::string const& prompt) const
	{
		if(!_helper->ref && AuthorizationCreate(nullptr, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &_helper->ref) != errAuthorizationSuccess)
			return false;

		AuthorizationItem rightItems[]        = { { right, 0, nullptr, 0 } };
		AuthorizationRights const rights      = { 1, rightItems };
		AuthorizationItem environmentItems[]  = { { kAuthorizationEnvironmentPrompt, prompt.size(), (void*)prompt.data(), 0 } };
		AuthorizationEnvironment const env    = { prompt.empty() ? 0U : 1U, environmentItems };

		OSStatus status = AuthorizationCopyRights(_helper->ref, &rights, &env, kAuthorizationFlagInteractionAllowed|kAuthorizationFlagExtendRights, nullptr);
		if(status != errAuthorizationSuccess && status != errAuthorizationCanceled)
			os_log_error(OS_LOG_DEFAULT, "Unable to obtain authorization right ‘%{public}s’: %d", right, (int)status);
		return status == errAuthorizationSuccess;
	}

	std::string authorization_t::external_form () const
	{
		AuthorizationExternalForm extForm;
		if(_helper->ref && AuthorizationMakeExternalForm(_helper->ref, &extForm) == errAuthorizationSuccess)
			return std::string((char const*)&extForm, sizeof(extForm));
		return std::string();
	}

} /* osx */

// =====================
// = Privileged Helper =
// =====================

namespace
{
	NSString* to_ns (std::string const& str) { return [[NSString alloc] initWithBytes:str.data() length:str.size() encoding:NSUTF8StringEncoding]; }
	NSData* to_data (std::string const& str) { return [NSData dataWithBytes:str.data() length:str.size()]; }
	std::string to_s (NSString* str)         { return str ? std::string(str.UTF8String) : NULL_STR; }
	std::string to_s (NSData* data)          { return data ? std::string((char const*)data.bytes, data.length) : std::string(); }

	SMAppService* service ()
	{
		return [SMAppService daemonServiceWithPlistName:@kPrivilegedHelperLabel ".plist"];
	}

	void show_alert (NSString* message, NSString* informativeText)
	{
		NSAlert* alert        = [[NSAlert alloc] init];
		alert.messageText     = message;
		alert.informativeText = informativeText;
		[alert runModal];
	}

	bool helper_is_enabled ()
	{
		SMAppService* helper = service();

		NSError* error;
		if(helper.status == SMAppServiceStatusNotRegistered && ![helper registerAndReturnError:&error])
			os_log_info(OS_LOG_DEFAULT, "Register privileged helper: %{public}@", error);

		switch(helper.status)
		{
			case SMAppServiceStatusEnabled:
				return true;

			case SMAppServiceStatusRequiresApproval:
			{
				NSAlert* alert        = [[NSAlert alloc] init];
				alert.messageText     = @"Allow OakMate to edit files that require administrator privileges?";
				alert.informativeText = @"In System Settings → General → Login Items & Extensions, turn on OakMate under “Allow in the Background”, then try again.";
				[alert addButtonWithTitle:@"Open System Settings"];
				[alert addButtonWithTitle:@"Cancel"];
				if([alert runModal] == NSAlertFirstButtonReturn)
					[SMAppService openSystemSettingsLoginItems];
			}
			return false;

			default:
				show_alert(@"Unable to register OakMate’s privileged helper.", error.localizedDescription ?: @"The helper could not be found in the application bundle.");
			return false;
		}
	}

	// Sends a message to the helper and waits for the reply. The handler must call the reply block that it is given exactly once.
	std::string send_request (void(^handler)(id<OakPrivilegedHelper> proxy, void(^reply)(NSString* error)))
	{
		NSXPCConnection* connection = [[NSXPCConnection alloc] initWithMachServiceName:@kPrivilegedHelperLabel options:NSXPCConnectionPrivileged];
		connection.remoteObjectInterface = OakPrivilegedHelperInterface();
		[connection resume];

		__block NSString* res = @"No reply from OakMate’s privileged helper.";
		id<OakPrivilegedHelper> proxy = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError* error){
			res = [NSString stringWithFormat:@"Unable to communicate with OakMate’s privileged helper: %@", error.localizedDescription];
		}];

		handler(proxy, ^(NSString* error){
			res = error;
		});

		[connection invalidate];
		return res ? to_s(res) : NULL_STR;
	}
}

namespace privileged_helper
{
	bool authorize (osx::authorization_t const& auth, std::string const& prompt)
	{
		if(!helper_is_enabled())
			return false;

		// Launching the helper makes it define the authorization right that we obtain below
		std::string error = send_request(^(id<OakPrivilegedHelper> proxy, void(^reply)(NSString*)){
			[proxy prepareWithReply:reply];
		});

		if(error != NULL_STR)
		{
			show_alert(@"Unable to start OakMate’s privileged helper.", to_ns(error));
			return false;
		}

		return auth.obtain_right(kAuthRightName, prompt);
	}

	std::string read_file (std::string const& path, osx::authorization_t const& auth, std::string& content, std::map<std::string, std::string>& attributes)
	{
		__block std::string blockContent;
		__block std::map<std::string, std::string> blockAttributes;
		std::string error = send_request(^(id<OakPrivilegedHelper> proxy, void(^reply)(NSString*)){
			[proxy readFileAtPath:to_ns(path) authorization:to_data(auth.external_form()) reply:^(NSData* content, NSDictionary<NSString*, NSData*>* attributes, NSString* error){
				blockContent = to_s(content);
				for(NSString* key in attributes)
					blockAttributes.emplace(to_s(key), to_s(attributes[key]));
				reply(error);
			}];
		});

		content    = blockContent;
		attributes = blockAttributes;
		return error;
	}

	std::string write_file (std::string const& path, std::string const& content, std::map<std::string, std::string> const& attributes, osx::authorization_t const& auth)
	{
		NSMutableDictionary* dict = [NSMutableDictionary dictionary];
		for(auto const& pair : attributes)
			dict[to_ns(pair.first)] = to_data(pair.second);

		return send_request(^(id<OakPrivilegedHelper> proxy, void(^reply)(NSString*)){
			[proxy writeData:to_data(content) attributes:dict toFileAtPath:to_ns(path) authorization:to_data(auth.external_form()) reply:reply];
		});
	}

	std::string copy_file (std::string const& source, std::string const& destination, osx::authorization_t const& auth)
	{
		return send_request(^(id<OakPrivilegedHelper> proxy, void(^reply)(NSString*)){
			[proxy copyFileAtPath:to_ns(source) toPath:to_ns(destination) authorization:to_data(auth.external_form()) reply:reply];
		});
	}

	std::string remove_file (std::string const& path, osx::authorization_t const& auth)
	{
		return send_request(^(id<OakPrivilegedHelper> proxy, void(^reply)(NSString*)){
			[proxy removeFileAtPath:to_ns(path) authorization:to_data(auth.external_form()) reply:reply];
		});
	}

	void unregister ()
	{
		SMAppService* helper = service();
		NSError* error;
		if(helper.status != SMAppServiceStatusNotRegistered && ![helper unregisterAndReturnError:&error])
			os_log_error(OS_LOG_DEFAULT, "Unregister privileged helper: %{public}@", error);
	}

} /* privileged_helper */
