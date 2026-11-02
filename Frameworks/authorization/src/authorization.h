#ifndef OSX_AUTHORIZATION_H_ST1ZIKX9
#define OSX_AUTHORIZATION_H_ST1ZIKX9

#include <oak/oak.h>

namespace osx
{
	// An AuthorizationRef shared by all copies. It is created on first use and holds the rights obtained until the last copy is destroyed.
	struct authorization_t
	{
		// Asks the user to authenticate unless the right is already held. Must be called on the main thread.
		bool obtain_right (char const* right, std::string const& prompt) const;

		// The bytes of an AuthorizationExternalForm, which the privileged helper verifies, or an empty string
		std::string external_form () const;

	private:
		struct helper_t
		{
			~helper_t () { if(ref) AuthorizationFree(ref, kAuthorizationFlagDestroyRights); }
			AuthorizationRef ref = nullptr;
		};

		std::shared_ptr<helper_t> _helper = std::make_shared<helper_t>();
	};

} /* osx */

#endif /* end of include guard: OSX_AUTHORIZATION_H_ST1ZIKX9 */
