#include "events.h"
#include "path.h"
#include "fsevents.h"
#include <oak/debug.h>

namespace
{
	bool operator== (timespec const& lhs, timespec const& rhs)
	{
		return lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec;
	}

	struct file_info_t
	{
		file_info_t (std::string const& path) : _path(path), _exists(false)
		{
			struct stat buf;
			if(lstat(path.c_str(), &buf) == 0)
			{
				_exists    = true;
				_mode      = buf.st_mode;
				_mtimespec = buf.st_mtimespec;
				_ctimespec = buf.st_ctimespec;
			}
		}

		std::string const& path () const               { return _path; }
		bool exists () const                           { return _exists; }
		bool is_directory () const                     { return _exists && S_ISDIR(_mode); }
		bool operator!= (file_info_t const& rhs) const { return !(*this == rhs); }

		bool operator== (file_info_t const& rhs) const
		{
			return _path == rhs._path && (_exists ? rhs._exists && _mode == rhs._mode && _mtimespec == rhs._mtimespec && _ctimespec == rhs._ctimespec : !rhs._exists);
		}

	private:
		std::string _path;
		bool _exists;
		mode_t _mode;
		timespec _mtimespec; // { tv_sec, tv_nsec }
		timespec _ctimespec;
	};

	static std::string real_path (std::string const& path)
	{
		if(char* tmp = realpath(path.c_str(), nullptr))
		{
			std::string str = tmp;
			free(tmp);
			return str;
		}
		return path;
	}

	struct events_t
	{
		struct stream_t
		{
			stream_t (std::string const& path, fs::event_callback_t* calback, uint64_t eventId, CFTimeInterval latency) : _requested(path), _observed(real_path(path)), _callback(calback), _event_id(eventId), _replay(false)
			{
				_requestedExists = true;

				while(!_observed.is_directory() && _observed.path() != "/")
				{
					_observed = file_info_t(path::parent(_observed.path()));
					_requestedExists = false;
				}

				set_replaying_history(eventId != kFSEventStreamEventIdSinceNow, path, eventId);

				_stream = std::make_shared<fs::event_stream_t>(std::vector<std::string>{ _observed.path() }, ^(std::vector<fs::event_t> const& events){
					did_receive_events(events);
				}, eventId, latency);

				if(!*_stream)
					os_log_error(OS_LOG_DEFAULT, "Can’t observe ‘%{public}s’", path.c_str());

				_event_id = std::max(_event_id, FSEventsGetCurrentEventId());
			}

			void set_replaying_history (bool flag, std::string const& observedPath, uint64_t eventId)
			{
				if(flag != _replay)
				{
					_replay = flag;
					_event_id = std::max(eventId, _event_id);
					_callback->set_replaying_history(flag, observedPath, flag ? eventId : _event_id);
				}
			}

			void did_receive_events (std::vector<fs::event_t> const& events);

			fs::event_stream_ptr _stream;
			file_info_t _requested;
			file_info_t _observed;
			fs::event_callback_t* _callback;
			uint64_t _event_id;
			bool _replay;
			bool _requestedExists;
		};

		typedef std::shared_ptr<stream_t> stream_ptr;
		std::vector<stream_ptr> streams;
		std::mutex streams_mutex;

		void watch (std::string const& path, fs::event_callback_t* cb, uint64_t eventId, CFTimeInterval latency)
		{
			auto stream = std::make_shared<stream_t>(path, cb, eventId, latency);

			std::lock_guard<std::mutex> lock(streams_mutex);
			streams.push_back(stream);
		}

		void unwatch (std::string const& path, fs::event_callback_t* cb)
		{
			std::lock_guard<std::mutex> lock(streams_mutex);
			iterate(it, streams)
			{
				if((*it)->_requested.path() == path && (*it)->_callback == cb)
				{
					// Events are handled on the main queue, so the stream must be destroyed there
					stream_ptr stream = *it;
					streams.erase(it);
					if(!pthread_main_np())
						dispatch_async(dispatch_get_main_queue(), ^{ stream_ptr dispose = stream; });
					return;
				}
			}
			os_log_error(OS_LOG_DEFAULT, "Not watching ‘%{public}s’", path.c_str());
		}
	};

	void events_t::stream_t::did_receive_events (std::vector<fs::event_t> const& events)
	{
		stream_t& stream = *this;
		uint64_t lastEventId = 0;
		for(auto const& event : events)
		{
			std::string path = event.path;
			std::string const& requestedPath = stream._requested.path();

			if(stream._requestedExists && requestedPath != stream._observed.path())
				path = path::join(requestedPath, path::relative_to(path, stream._observed.path()));

			if(event.flags & kFSEventStreamEventFlagHistoryDone)
			{
				ASSERT(stream._replay);
				stream.set_replaying_history(false, requestedPath, event.id);
			}
			else
			{
				if(!stream._requested.exists()) // check if it has been created
				{
					std::string const parentPath = path::parent(requestedPath);
					if(path.compare(0, parentPath.size(), parentPath) == 0)
					{
						stream._requested = file_info_t(requestedPath);
						if(stream._requested.exists())
						{
							if(!stream._requested.is_directory())
								stream._callback->did_change(requestedPath, requestedPath, event.id, event.flags & kFSEventStreamEventFlagMustScanSubDirs);
							else if(path.compare(0, requestedPath.size(), requestedPath) == 0)
								stream._callback->did_change(path, requestedPath, event.id, event.flags & kFSEventStreamEventFlagMustScanSubDirs);
						}
					}
				}
				else if(!stream._requested.is_directory()) // check if file was modified
				{
					if(path == path::parent(requestedPath))
					{
						file_info_t newInfo(requestedPath);
						if(stream._requested != newInfo)
						{
							stream._requested = newInfo;
							stream._callback->did_change(requestedPath, requestedPath, event.id, event.flags & kFSEventStreamEventFlagMustScanSubDirs);
						}
						else
						{
							// fprintf(stderr, "file not changed: %s\n", requestedPath.c_str());
						}
					}
					else
					{
						// fprintf(stderr, "skipping %s (watching %s, requested %s)\n", path.c_str(), stream._observed.path().c_str(), requestedPath.c_str());
					}
				}
				else if(path.compare(0, requestedPath.size(), requestedPath) == 0) // make sure the event is in our observed directory
				{
					stream._callback->did_change(path, requestedPath, event.id, event.flags & kFSEventStreamEventFlagMustScanSubDirs);
				}
				else
				{
					// this happens if we setup observing for a non-existing directory which is later created
					// fprintf(stderr, "skipping %s (watching %s, requested %s)\n", path.c_str(), stream._observed.path().c_str(), requestedPath.c_str());
				}

				lastEventId = event.id;
			}
		}

		if(!stream._replay && lastEventId)
			stream._event_id = lastEventId;
	}
}

namespace fs
{
	static events_t& events ()
	{
		static events_t events;
		return events;
	}

	void watch (std::string const& path, event_callback_t* callback, uint64_t eventId, CFTimeInterval latency)
	{
		events().watch(path, callback, eventId, latency);
	}

	void unwatch (std::string const& path, event_callback_t* callback)
	{
		events().unwatch(path, callback);
	}

} /* fs */
