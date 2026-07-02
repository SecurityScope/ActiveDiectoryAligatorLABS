# vagrant_plugins/winrm_quiet.rb
# Suppresses WinRM cleanup errors after AD DS promotion.
require 'winrm'

module WinRM
  module Shells
    class Base
      alias_method :_original_close, :close
      def close
        _original_close
      rescue => e
        # Silently swallow cleanup errors after AD DS promotion
      end
    end
  end
end
