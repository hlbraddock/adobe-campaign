# frozen_string_literal: true
module Adobe
  module Campaign
    class Profile < Adobe::Campaign::Base
      def self.endpoint
        'profileAndServices/profile'
      end

      # Example Create Payload
      # {
      #   "birthDate": '',
      #   "email": 'a.test@cru.org',
      #   "emailFormat": 'unknown',
      #   "fax": '',
      #   "firstName": 'A Test',
      #   "gender": 'male',
      #   "lastName": 'Profile',
      #   "location": {
      #     "address1": '123 North St',
      #     "address2": '',
      #     "address3": '',
      #     "address4": '',
      #     "city": 'Orlando',
      #     "countryCode": 'US',
      #     "stateCode": 'FL',
      #     "zipCode": '32714'
      #   },
      #   "middleName": '',
      #   "mobilePhone": '',
      #   "phone": '',
      #   "salutation": 'Mr'
      # }
    end
  end
end