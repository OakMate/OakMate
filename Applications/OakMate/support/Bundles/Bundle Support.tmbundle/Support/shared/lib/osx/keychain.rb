# encoding: utf-8

# Internet passwords in the user’s keychain, using security(1).
#
#   OSX::Keychain.internet_password_for(:account => 'duff', :server => 'example.com', :protocol => 'http')
#   OSX::Keychain.set_internet_password_for(:account => 'duff', :server => 'example.com', :protocol => 'http', :password => 'secret')
#
# Optional keys are :port and :path. The protocol is a four character code
# such as 'http', 'ftp ', 'mysq', or 'pgsq'.

module OSX
  module Keychain
    class << self
      def internet_password_for(options)
        args = [ '/usr/bin/security', 'find-internet-password', '-w', *item_arguments(options) ]
        password = ::IO.popen(args, err: File::NULL, &:read)
        $?.success? ? password.chomp : nil
      end

      def set_internet_password_for(options)
        password = options.fetch(:password) { raise ArgumentError, 'password required' }
        system('/usr/bin/security', 'add-internet-password', '-U', *item_arguments(options), '-w', password.to_s, out: File::NULL, err: File::NULL)
      end

      private

      def item_arguments(options)
        res = []
        res += [ '-a', options.fetch(:account)  { raise ArgumentError, 'account required'  }.to_s ]
        res += [ '-s', options.fetch(:server)   { raise ArgumentError, 'server required'   }.to_s ]
        res += [ '-r', options.fetch(:protocol) { raise ArgumentError, 'protocol required' }.to_s ]
        res += [ '-P', options[:port].to_s ] if options[:port]
        res += [ '-p', options[:path].to_s ] if options[:path]
        res
      end
    end
  end
end
