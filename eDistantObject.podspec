Pod::Spec.new do |s|
	s.name					= "eDistantObject"
	s.version				= "1.0.0"
	s.summary				= "ObjC and Swift remote invocation framework"
	s.homepage				= "https://github.com/google/eDistantObject"
	s.author 				= "Google Inc."
	s.summary				= "eDistantObject provides users an easy way to make remote invocations between processes in Objective-C and Swift without explicitly constructing RPC structures."
	s.license				= { :type => "Apache 2.0", :file => "LICENSE" }
	s.source				= { :git => "https://github.com/google/eDistantObject.git", :tag => "master" }
	s.source_files			= "Channel/Sources/*.{m,h}", "Service/Sources/*.{m,h}", "Measure/Sources/*.{m,h}", "Device/Sources/*.{m,h}"
	s.public_header_files	= "Service/Sources/EDOClientService.h", "Service/Sources/EDOClientService+Device.h", "Service/Sources/EDOClientServiceStatsCollector.h", "Service/Sources/EDOHostNamingService.h", "Service/Sources/EDOHostService.h", "Service/Sources/EDOHostService+Device.h", "Service/Sources/EDORemoteVariable.h", "Service/Sources/EDOServiceError.h", "Service/Sources/EDOServiceException.h", "Service/Sources/EDOServicePort.h", "Service/Sources/NSObject+EDOValueObject.h", "Device/Sources/EDODeviceConnector.h", "Device/Sources/EDODeviceDetector.h"
	s.private_header_files		= "Channel/Sources/*.h", "Service/Sources/*.h", "Measure/Sources/*.h", "Device/Sources/*.h"
end


