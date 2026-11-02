#ifndef PRIVILEGED_HELPER_H_Q2W7NB4C
#define PRIVILEGED_HELPER_H_Q2W7NB4C

#include "authorization.h"
#include <oak/oak.h>

namespace privileged_helper
{
	// Makes sure the helper is allowed to run (showing an alert that leads to System Settings when it is not) and asks the user to authenticate with the given prompt. Must be called on the main thread.
	bool authorize (osx::authorization_t const& auth, std::string const& prompt);

	// The functions below block until the helper replies and return an error message or NULL_STR on success. They may be called on any thread after authorize().
	std::string read_file (std::string const& path, osx::authorization_t const& auth, std::string& content, std::map<std::string, std::string>& attributes);
	std::string write_file (std::string const& path, std::string const& content, std::map<std::string, std::string> const& attributes, osx::authorization_t const& auth);
	std::string copy_file (std::string const& source, std::string const& destination, osx::authorization_t const& auth);
	std::string remove_file (std::string const& path, osx::authorization_t const& auth);

	// Removes the helper from launchd, e.g. when uninstalling OakMate
	void unregister ();

} /* privileged_helper */

#endif /* end of include guard: PRIVILEGED_HELPER_H_Q2W7NB4C */
