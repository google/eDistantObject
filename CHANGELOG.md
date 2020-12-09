# Change Log

Details changes in each release of eDistantObject. eDistantObject follows
[semantic versioning](http://semver.org/).

## [1.0.2](https://github.com/google/eDistantObject/tree/1.0.2) (12/09/2020)

* Added supports to ASAN/TSAN/UBSAN.

* Fixed "Doesn't support pointer returns" complaint when eDO is proxying Swift
  array.

## [1.0.1](https://github.com/google/eDistantObject/tree/1.0.1) (09/01/2020)

Aligned with Google respectful code guidance and renamed some classes.

## [1.0.0](https://github.com/google/eDistantObject/tree/1.0.0) (08/14/2020)

Updates:

* Bring the concept of `originatingQueues` and `executingQueue` into
  EDOHostService, which can be accessed and manipulated through the initializers
  and properties of the class. It allows a queue to redirect the callbacks of
  its remote invocations to another queue, and optimize the load balance.

    * `originatingQueues`: Each EDOHostService holds a list of queues as
      `originatingQueues`. If local objects are boxed on any queue of
      `originatingQueues`, the corresponding EDOHostService will be the target
      of the produced eDO proxy. A queue can be belong to only one
      `originatingQueues`.
    * `executingQueue`: Each EDOHostService holds exactly one queue as
      `executingQueue`. When an EDOHostService is targeted by an eDO proxy, the
      EDOHostService will always execute the request on the `executingQueue`. If
      a queue is the `executingQueue` of a EDOHostService, it must also belong
      to the `originatingQueues` of the same service.

* The exceptions, thrown during eDO remote invocations, will contain the stack
  traces of both the callee process and previous caller processes.

* You can
  [block](https://github.com/google/eDistantObject/blob/master/Service/Sources/NSObject%2BEDOBlockedType.h#L38)
  certain class type to be wrapped as an eDO proxy, to help detect unexpected
  object creation in the wrong process.

Fixes:

* [Fixed](https://github.com/google/eDistantObject/commit/ddeeac61eec7bdaa87c2f817120a0e553f15e8f4) a deadlock that can happen in nested eDO invocations.

## [0.9.0](https://github.com/google/eDistantObject/tree/0.9.0) (05/31/2019)

Initial release of eDistantObject.

eDistantObject (eDO) is an easy to use Remote Method Invocation (RMI) library.
eDO is a component of [EarlGrey2](https://github.com/google/EarlGrey/tree/earlgrey2).
It allows for remote invocations across architectures in both Objective-C and
Swift without explicitly constructing Remote Procedure Call (RPC) structures.
