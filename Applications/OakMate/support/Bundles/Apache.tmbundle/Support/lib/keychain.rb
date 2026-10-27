# Simple interface for reading and writing generic passwords to
# the KeyChain.
module KeyChain
  class << self

    # Adds a generic password to the users keychain using the specified 
    # Account, Service and Password paramaters.
    # Example: security add-generic-password -a "TextMate Bundles" -s "Apache.tmbundle" -p "test-password"     
    def add_generic_password(account, service, pass)
      system('/usr/bin/security', 'add-generic-password', '-U', '-a', account.to_s, '-s', service.to_s, '-w', pass.to_s, out: File::NULL, err: File::NULL)
    end
    
    # Locates a generic password from the users keychain. 
    def find_generic_password(account, service)
      result = ::IO.popen([ '/usr/bin/security', 'find-generic-password', '-w', '-a', account.to_s, '-s', service.to_s ], err: File::NULL, &:read)
      $?.success? ? result.chomp : nil
    end
    
  end
end
