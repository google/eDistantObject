Pod::Spec.new do |s|
  s.name = "eDistantObject"
  s.version = "1.0.2"
  s.summary = "ObjC and Swift remote invocation framework"
  s.homepage = "https://github.com/google/eDistantObject"
  s.author = "Google LLC."
  s.description = <<-DESC
            eDistantObject provides users an easy way to make remote method invocations between
            processes in Objective-C and Swift without explicitly constructing RPC structures.
            DESC
  s.license = { :type => "Apache 2.0", :file => "LICENSE" }
  s.source = { :git => "https://github.com/google/eDistantObject.git", :tag => "1.0.1" }

  s.public_header_files = %w[Service/Sources/EDOClientService.h
                             Service/Sources/EDOClientServiceStatsCollector.h
                             Service/Sources/EDOHostNamingService.h
                             Service/Sources/EDOHostService.h
                             Service/Sources/EDORemoteException.h
                             Service/Sources/EDORemoteVariable.h
                             Service/Sources/EDOServiceError.h
                             Service/Sources/EDOServiceException.h
                             Service/Sources/EDOServicePort.h
                             Service/Sources/NSObject+EDOBlockedType.h
                             Service/Sources/NSObject+EDOValueObject.h
                             Service/Sources/NSObject+EDOWeakObject.h
                             Device/Sources/EDODeviceConnector.h
                             Device/Sources/EDODeviceDetector.h
                           ]

  # ${PODS_TARGET_SRCROOT} is needed for Pod lint which locates the local eDistantObject codebase.
  s.pod_target_xcconfig = { "HEADER_SEARCH_PATHS" => "${PODS_ROOT}/eDistantObject ${PODS_TARGET_SRCROOT}" }
  s.source_files = "Channel/Sources/*.{m,h}", "Device/Sources/*.{m,h}",
                   "Measure/Sources/*.{m,h}", "Service/Sources/*.{m,h,swift}"

  s.ios.deployment_target = "10.0"
  s.osx.deployment_target = "10.10"
end
