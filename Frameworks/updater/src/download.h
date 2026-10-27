#ifndef UPDATER_DOWNLOAD_H_842XT36M
#define UPDATER_DOWNLOAD_H_842XT36M

#include <oak/oak.h>

namespace bundles_db
{
	std::string download_etag (std::string const& url, std::string* etag, double* progress, double min, double max);

} /* bundles_db */

#endif /* end of include guard: UPDATER_DOWNLOAD_H_842XT36M */
