module Seek
  module BioSchema
    module ResourceWrappers
      class Person < ResourceWrapper
        def url
          web_page.blank? ? identifier : web_page
        end
      end
    end
  end
end
