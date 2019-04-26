//
//  froop.swift
//  froop
//
//  Created by martin on 2019-02-23.
//  Copyright © 2019 Lookback Ltd. All rights reserved.
//
import Foundation

/// Global singelton that can redirect the froop logging from .debug()
public var froopLog: (String, String) -> Void = {
    label, message in
    print("\(label) \(message)")
}

private var streamCount: Locker<UInt64> = Locker(value: 0)

/// Stream of vaules over time. Typically created by a FSink.
///
/// ```
/// let sink = FSink<Int>()
///
/// let stream = sink.stream()
/// let double = stream.map() { $0 * 2 }
///
/// sink.update(0)
/// sink.update(1)
/// ...
/// ```
///
/// For some detailed notes on how a combinator is structured for ARC and thread
/// safety, see the source code for the `.map()` function. All operations follow
///  a similar pattern.
public class FStream<T>: Equatable {
    fileprivate let inner: Locker<Inner<T>>
    fileprivate var parent: Peg? = nil
    fileprivate let ident: UInt64 = streamCount.withValue() {
        $0 += 1
        return $0
    }

    public static func == (lhs: FStream, rhs: FStream) -> Bool {
        return lhs.ident == rhs.ident
    }

    /// A new stream with a new inner
    fileprivate init(memoryMode: MemoryMode) {
        self.inner = Locker(value:Inner(memoryMode))
    }
    
    /// A new stream with a cloned inner
    fileprivate init(inner: Locker<Inner<T>>) {
        self.inner = inner
    }

    // TODO: Not sure this function makes much sense since it injects the
    // value _straight away_. It encourages dependening on that behavior of
    // making values flow already at initialisation.
    //    /// Create a new stream that emits one single value to any subscriber.
    //    ///
    //    /// The stream is in memory mode.
    //    public static func of(value: T) -> FMemoryStream<T> {
    //        let stream = FMemoryStream<T>(memoryMode: MemoryMode.AfterEnd)
    //        stream.inner.withValue() {
    //            $0.update(value)
    //            $0.update(nil)
    //        }
    //        return stream
    //    }

    /// Create a stream that never emits anything. It stays inerts forever.
    public static func never() -> FStream<T> {
        let stream = FStream(memoryMode: .NoMemory)
        stream.inner.withValue() { $0.update(nil) }
        return stream
    }
    
    /// Subscribe to values from this stream.
    @discardableResult
    public func subscribe(_ listener: @escaping (T) -> Void ) -> Subscription<T> {
        return self.inner.withValue() {
            let strong = $0.subscribeStrong(peg: self.parent) {
                if let t = $0 {
                    listener(t)
                }
            }
            return Subscription(strong)
        }
    }

    /// Subscribe to the end of the stream
    @discardableResult
    public func subscribeEnd(_ listener: @escaping () -> Void ) -> Subscription<T> {
        return self.inner.withValue() {
            let strong = $0.subscribeStrong(peg: self.parent) {
                if $0 == nil {
                    listener()
                }
            }
            return Subscription(strong)
        }
    }

    /// Internal subscribe that returns a `Peg` which is used to keep
    /// a weak reference alive of a listener to the parent stream.
    fileprivate func subscribeInner(_ listener: @escaping (T?) -> Void ) -> Peg {
        // Peg for the new weak subscription.
        var peg = self.inner.withValue() {
            $0.subscribeWeak(onvalue: listener)
        }
        // This peg must also keep the parent stream alive.
        // This is for chained operators such as .map().filter().map()
        // where the intermediaries would be unsubscribed otherwise.
        peg.parent = self.parent as AnyObject
        return peg
    }
    
    /// Collect values of this stream into an array of values.
    public func collect() -> Collector<T> {
        let c = Collector<T>()
        c.parent = self.subscribeInner(c.update)
        return c
    }

    /// Print every object passing through this stream prefixed by the `label`.
    public func debug(_ label: String) -> FStream<T> {
        return self.map() {
            froopLog(label, String(describing: $0))
            return $0
        }
    }

    /// Dedupe the stream by extracting some equatable value from it.
    /// The value is compared for consecutive elements.
    public func dedupeBy<U: Equatable>(_ f: @escaping (T) -> U) -> FStream<T> {
        let stream = FStream(memoryMode: .NoMemory)
        let inner = stream.inner
        var lastU: U? = nil
        stream.parent = self.subscribeInner() {
            if let t = $0 {
                let newU = f(t)
                if lastU != newU {
                    lastU = newU
                    inner.withValue() { $0.update(t) }
                }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Drop a fixed number of initial values, then start emitting.
    public func drop(amount: UInt) -> FStream<T> {
        var todo = amount + 1
        return self.dropWhile() { _ in
            if todo > 0 {
                todo -= 1
            }
            return todo > 0
        }
    }
    
    /// Drop values while some condition holds true, then start emitting.
    /// Once started emitting, it will never drop again.
    public func dropWhile(_ f: @escaping (T) -> Bool) -> FStream<T> {
        let stream = FStream(memoryMode: .NoMemory)
        let inner = stream.inner
        var dropping = true
        stream.parent = self.subscribeInner() {
            if let t = $0 {
                if dropping {
                    dropping = f(t)
                }
                if !dropping {
                    inner.withValue() { $0.update(t) }
                }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Make a stream that ends when some other stream ends.
    public func endWhen<U>(other: FStream<U>) -> FStream<T> {
        let stream = FStream(memoryMode: .NoMemory)
        let inner = stream.inner
        let p1 = self.subscribeInner() { t in
            // regular values or end, both are propagated
            inner.withValue() { $0.update(t) }
        }
        let p2 = other.subscribeInner() {
            // ignore regular values, just look out for the end
            if $0 == nil {
                inner.withValue() { $0.update(nil) }
            }
        }
        // peg both parent and other
        stream.parent = Peg(pegs: [p1, p2])
        return stream
    }
    
    /// Filter the stream using some sort of test.
    public func filter(_ f: @escaping (T) -> Bool) -> FStream<T> {
        let stream = FStream(memoryMode: .NoMemory)
        let inner = stream.inner
        stream.parent = self.subscribeInner() {
            if let t = $0 {
                if f(t) {
                    inner.withValue() { $0.update(t) }
                }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }

    /// Filter the stream and also transform the value.
    public func filterMap<U>(_ f: @escaping (T) -> U?) -> FStream<U> {
        let stream = FStream<U>(memoryMode: .NoMemory)
        let inner = stream.inner
        stream.parent = self.subscribeInner() {
            if let t = $0 {
                let u = f(t)
                if u != nil {
                    inner.withValue() { $0.update(u) }
                }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Fold the stream by combining values from the past with the new value.
    /// The seed is emitted as the first value.
    ///
    /// This is roughly equivalent of an `Array.reduce()` or `Array.fold()`.
    public func fold<U>(_ seed: U, _ f: @escaping (U, T) -> U) -> FMemoryStream<U> {
        let stream = FMemoryStream<U>(memoryMode: .UntilEnd)
        let inner = stream.inner
        // emit seed as first value
        inner.withValue() { $0.update(seed) }
        // keep track of previous value
        var prev = seed
        stream.parent = self.subscribeInner() {
            if let t = $0 {
                let next = f(prev, t)
                prev = next
                inner.withValue() { $0.update(next) }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Internal function that starts an imitator.
    fileprivate func attachImitator(_ imitator: FImitator<T>) -> Subscription<T> {
        let inner = imitator.inner;
        return self.inner.withValue() {
            let strong = $0.subscribeStrong(peg: self.parent) { t in
                // an imitation is a "todo" closure that captures the value to be
                // dispatched later into the imitator. the todo is added to a
                // thread local and is called later, after the current evaluation
                // finishes.
                let todo: Imitation = {
                    inner.withValue() { $0.update(t) }
                }
                imitations.withValue() {
                    $0.withValue() {
                        $0.append(todo)
                    }
                }
            }
            return Subscription(strong)
        }
    }
    
    /// Makes a stream that only emits the last value.
    public func last() -> FStream<T> {
        let stream = FStream(memoryMode: .NoMemory)
        let inner = stream.inner
        var lastValue: T? = nil
        stream.parent = self.subscribeInner() {
            if let t = $0 {
                lastValue = t
            } else {
                inner.withValue() {
                    if lastValue != nil {
                        $0.update(lastValue)
                    }
                    $0.update(nil)
                }
            }
        }
        return stream
    }
    
    /// Transform values of type T to type U.
    public func map<U>(_ f: @escaping (T) -> U) -> FStream<U> {
        // We want to add a listener to `self` and create a new `FStream` instance
        // that receives updates from that listener and apply the transform
        // `f` to incoming values.
        //
        // However if we drop the new stream instance, we don't want it to be
        // kept alive by a strong reference from the listener.
        //
        // Consider a stream of streams:
        // ```
        //   let s: FStream<FStream<Int>> = ...
        //   let x: FStream<Int> = s.map() { innerStream ->
        //      innerStream.map() { $0 + 1 }
        //   }
        //   .flatten()
        // ```
        //
        // The inner `.map()` instance will be dropped/recreated for every innerStream
        // value. It's clear we don't want it to be kept alive after the .filter() instance
        // drops.
        //
        // This is where `subscribeInner` comes in. It adds a weak listener to `self`
        // and returns a `Peg` that is an opaque wrapper for the strong reference to
        // the listener. That "peg" then lives inside the new stream instance and thus
        // when they drop together, we automatically "unsubscribe" the weak listener.
        let stream = FStream<U>(memoryMode: .NoMemory)
        
        // We can't use "stream" inside the closure since that would capture the stream instance
        // and thus also the "peg" described above (we would get a cyclic dependency keeping the
        // tree alive). So we get an ARC reference to the inner, which is used to dispatch values.
        let inner = stream.inner;
        
        // We subscribe to self and back comes the "peg" that goes into the new stream.
        stream.parent = self.subscribeInner() {
            // If it is a value, transform it otherwise end.
            if let t = $0 {
                inner.withValue() { $0.update(f(t)) }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Transform any incoming value to one fixed value.
    public func mapTo<U>(value: U) -> FStream<U> {
        let stream = FStream<U>(memoryMode: .NoMemory)
        let inner = stream.inner
        stream.parent = self.subscribeInner() {
            if $0 != nil {
                inner.withValue() { $0.update(value) }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Make a stream that remembers the last value. Any new (or combinator) will get the
    /// last emitted value straight away.
    public func remember() -> FMemoryStream<T> {
        let stream = FMemoryStream<T>(memoryMode: .UntilEnd)
        let inner = stream.inner
        stream.parent = self.subscribeInner() { t in
            inner.withValue() { $0.update(t) }
        }
        return stream
    }
    
    /// For every value of this stream, take a sample of the last value of some other
    /// stream and combine the two.
    ///
    /// This stream becomes a kind of "trigger" for a value that is a combination of two.
    /// Useful when wanting to filter/gate one stream on a value from some other stream.
    ///
    /// No value will be emitted unless `other` has produced at least one value.
    public func sampleCombine<U>(_ other: FStream<U>) -> FStream<(T, U)> {
        let stream = FStream<(T, U)>(memoryMode: .NoMemory)
        let inner = stream.inner
        
        // keep track of last U. if this stream ends, we just hold on to the
        // last U forever.
        var lastU: U? = nil
        let p1 = other.subscribeInner() {
            if let u = $0 {
                lastU = u
            }
        }
        
        // for ever incoming value, combine the two
        let p2 = self.subscribeInner() {
            if let t = $0 {
                // only if we have a U
                if let u = lastU {
                    inner.withValue() { $0.update((t,u)) }
                }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        
        // keep both pegged
        stream.parent = Peg(pegs: [p1, p2])
        return stream
    }
    
    /// Prepend a value to a stream. Or in other words, give a start value to a stream.
    public func startWith(value: T) -> FMemoryStream<T> {
        let stream = FMemoryStream<T>(memoryMode: .UntilEnd)
        let inner = stream.inner
        inner.withValue() { $0.update(value) }
        stream.parent = self.subscribeInner() { t in
            inner.withValue() { $0.update(t) }
        }
        return stream
    }
    
    /// Take a fixed amount of elements, then end.
    public func take(amount: UInt) -> FStream<T> {
        var todo = amount + 1
        let stream = FStream<T>(memoryMode: .NoMemory)
        let inner = stream.inner
        stream.parent = self.subscribeInner() { t in
            if todo > 0 {
                todo -= 1
            }
            if todo > 0 {
                inner.withValue() { $0.update(t) }
            }
            if todo == 1 {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Take values from the stream while some condition hold true, then end the stream.
    public func takeWhile(_ f: @escaping (T) -> Bool) -> FStream<T> {
        let stream = FStream<T>(memoryMode: .NoMemory)
        let inner = stream.inner
        stream.parent = self.subscribeInner() {
            if let t = $0 {
                if f(t) {
                    inner.withValue() { $0.update(t) }
                } else {
                    inner.withValue() { $0.update(nil) }
                }
            } else {
                inner.withValue() { $0.update(nil) }
            }
        }
        return stream
    }
    
    /// Stall the thread until the stream to ends.
    public func wait() {
        let waitFor: Locker<DispatchSemaphore?> = Locker(value: DispatchSemaphore(value: 0))
        let peg = self.remember().subscribeInner() {
            if $0 == nil {
                waitFor.withValue() {
                    $0?.signal()
                    $0 = nil
                }
            }
        }
        ignore(peg)
        let w = waitFor.withValue() { $0 }
        w?.wait()
    }
    
}

extension FStream where T: Equatable {
    
    /// Dedupe the stream by the value in the stream itself
    public func dedupe() -> FStream<T> {
        func f(t: T) -> T { return t }
        return self.dedupeBy(f)
    }
    
}

/// Flatten a stream of streams, sequentially. This means that any new stream
/// effectively interrupts the previous stream and we only get values from
/// the latest stream.
///
/// Swift doesn't do recursive types, so we can't make an extension for this.
public func flatten<T>(nested: froop.FStream<froop.FStream<T>>) -> FStream<T> {
    let stream = FStream<T>(memoryMode: .NoMemory)
    let inner = stream.inner
    var currentIdent: UInt64 = 0
    var outerEnded = false
    var peg: Peg? = nil
    ignore(peg)
    stream.parent = nested.subscribeInner() {
        if let nestedStream = $0 {
            if currentIdent != nestedStream.ident {
                // simply overwriting the old value will release the ARC
                peg = nestedStream.subscribeInner() {
                    if let t = $0 {
                        inner.withValue() { $0.update(t) }
                    } else {
                        peg = nil
                        currentIdent = 0
                        // the inner stream ending ends if the outer is ended
                        if outerEnded {
                            inner.withValue() { $0.update(nil) }
                        }
                    }
                }
                currentIdent = nestedStream.ident
            }
        } else {
            outerEnded = true
            // the outer stream ending ends if inner is already ended, or not started
            if peg == nil {
                inner.withValue() { $0.update(nil) }
            }
        }
    }
    return stream
}

/// Flatten a stream of streams, concurrently. This means that any new stream
/// is just added to the current subscribed streams. We listen to all streams
/// coming.
///
/// Swift doesn't do recursive types, so we can't make an extension for this.
public func flattenConcurrently<T>(nested: froop.FStream<froop.FStream<T>>) -> FStream<T> {
    let stream = FStream<T>(memoryMode: .NoMemory)
    let currentIdents: Locker<[UInt64]> = Locker(value:[])
    let inner = stream.inner
    stream.parent = nested.subscribeInner() {
        if let nestedStream$ = $0 {
            var peg: Peg? = nil
            ignore(peg)
            let ident = nestedStream$.ident
            // simply overwriting the old value will release the ARC
            peg = nestedStream$.subscribeInner() {
                if let t = $0 {
                    inner.withValue() { $0.update(t) }
                } else {
                    // the inner stream ending does not end the result stream
                    peg = nil
                    currentIdents.withValue() { $0.removeAll() { $0 == ident } }
                }
            }
            currentIdents.withValue() { $0.append(ident) }
        } else {
            // the outer stream ending does end the result stream
            inner.withValue() { $0.update(nil) }
        }
    }
    return stream
}

/// Merge a bunch of streams emitting the same T to one.
public func merge<T>(_ streams: FStream<T>...) -> FStream<T> {
    let stream = FStream<T>(memoryMode: .NoMemory)
    let inner = stream.inner
    // TODO a better strategy would be to unsubscribe from streams as they end
    var count = streams.count
    let pegs = streams.map() { stream in stream.subscribeInner() {
        if let t = $0 {
            inner.withValue() { $0.update(t) }
        } else {
            count -= 1
            // only end stream when all merged streams end
            if count == 0 {
                inner.withValue() { $0.update(nil) }
            }
        }
        }
    }
    stream.parent = Peg(pegs: pegs)
    return stream
}

/// Specialization of FStream that has "memory". Memory means that any
/// new listener added will straight away get the last value that went through the stream.
public class FMemoryStream<T> : FStream<T> {
    // The actual implementation of this is entirely in the `Inner` class.
    // We just inherit to make a clearer type to the user of this API.
    
    fileprivate override init(memoryMode: MemoryMode) {
        super.init(memoryMode: memoryMode)
    }
}


/// The originator of a stream of values.
///
/// ```
/// let sink = FSink<Int>()
///
/// let stream = sink.stream()
///
/// ...
/// sink.update(0)
/// sink.update(1)
/// sink.end()
/// ```
public class FSink<T> {
    private var inner: Locker<Inner<T>> = Locker(value:Inner(.NoMemory))
    
    /// Create a new sink.
    public init() {
    }
    
    /// Get a stream from this sink. Can be used multiple times and each instance
    /// will be backed by the same sink.
    public func stream() -> FStream<T> {
        return FStream(inner: self.inner)
    }
    
    /// Update a value into the sink and all connected streams.
    public func update(_ t: T) {
        self.inner.withValue() { $0.updateAndImitate(t) }
    }
    
    /// End this sink. No more values can be sent after this.
    public func end() {
        self.inner.withValue() { $0.updateAndImitate(nil) }
    }
}



/// Helper to collect values from a stream. Mainly useful for tests.
public class Collector<T> {
    private let inner: Locker<CollectorInner<T>>
    fileprivate var parent: Peg? = nil
    
    fileprivate init() {
        inner = Locker(value: CollectorInner<T>())
    }
    
    fileprivate func update(_ t:T?) {
        self.inner.withValue() {
            if !$0.alive {
                return
            }
            if let t = t {
                $0.values.append(t)
            } else {
                $0.waitFor.signal()
                $0.alive = false
            }
        }
    }
    
    /// Stall the thread and wait for the stream this collector works off to end.
    public func wait() -> [T] {
        let waitFor = self.inner.withValue() {
            $0.alive ? $0.waitFor : nil
        }
        if let waitFor = waitFor {
            waitFor.wait()
        }
        return self.take()
    }
    
    /// Take whatever values are in the collector without waiting for
    /// the stream to end.
    public func take() -> [T] {
        return self.inner.withValue() {
            let v = $0.values;
            $0.values = []
            return v
        }
    }
}

fileprivate struct CollectorInner<T> {
    var alive = true
    var values: [T] = []
    let waitFor = DispatchSemaphore(value: 0)
}


/// Subscriptions are receipts to the `FStream.subscribe()` operation. They
/// can be used to unsubscribe.
///
/// ```
/// let sink = FSink<Int>()
///
/// let sub = sink.stream().subscribe() { print("\($0)") }
///
/// sink.update(0)
/// sub.unsubscribe()
/// sink.update(1) // not received
/// ```
public class Subscription<T> {
    private var strong: Strong<Listener<T>>?

    /// Set to true to automatically unsubscribe when the subscription deinits
    var unsubscribeOnDeinit: Bool = false
    
    fileprivate init(_ strong: Strong<Listener<T>>) {
        self.strong = strong
    }
    
    /// Unsubscribe from further updates.
    public func unsubscribe() {
        self.strong?.clear()
        self.strong = nil
    }

    deinit {
        if unsubscribeOnDeinit {
            self.unsubscribe()
        }
    }
}


/// Imitators are used to create cyclic streams. The imitator is an originator
/// of a stream at the same time as it imitates some other stream further down
/// the code.
///
/// Here's a bad idea illustrating the usage:
/// ```
/// let imitator = FImitator<Int>() stream of int
///
/// let x = imitator.stream().map() { $0 + 1 } // use imitator stream
/// let y: FStream<Int> = ...
///
/// let m = FStream.merge(x, y) // merge imiator with other stream
///
/// imitator.imitate(m) // cycle all m up to imitator, this can only be done once
///
/// // NB. This is a BAD IDEA, beacuse it causes an endless loop. FImitators must
/// // be used with care to not spin out of control.
/// ```
///
public class FImitator<T> {
    fileprivate var inner: Locker<Inner<T>> = Locker(value:Inner(.NoMemory))
    private var imitating = false

    public init() {
    }

    /// Get a stream from this imitator. Can be used multiple times and each instance
    /// will be backed by the same imitator.
    public func stream() -> FStream<T> {
        return FStream(inner: self.inner)
    }
    
    /// Start imitating another stream. This can be called exactly once.
    /// Repeated calls will `fatalError`.
    ///
    /// Imitators create a cyclic dependency. The imitator will end if the
    /// imitated stream ends, but if we want to break the cycle without
    /// ending streams, the returned subscription is used.
    @discardableResult
    public func imitate(other: FStream<T>) -> Subscription<T> {
        if self.imitating {
            fatalError("imitate() used twice on the same imitator")
        }
        self.imitating = true
        return other.attachImitator(self)
    }
}


/// Thread local collector of imitations that are to be done once the current stream
/// invocation finishes. This is how we make sync imitations happen.
///
/// Amazingly ThreadLocal is not thread safe, so we are forced to wrap it in a locker.
private let imitations: Locker<ThreadLocal<[Imitation]>> = Locker(value: ThreadLocal(value: []))
typealias Imitation = () -> Void



/// Helper type to thread safely lock a value L. It is accessed via a closure.
fileprivate class Locker<L> {
    private let semaphore = DispatchSemaphore(value: 1)
    private var value: L
    
    init(value: L) {
        self.value = value
    }
    
    /// Access the locked in value
    func withValue<X>(closure: (inout L) -> X) -> X {
        self.semaphore.wait()
        let x = closure(&self.value)
        self.semaphore.signal()
        return x
    }
}



/// The kinds of memory modes we have
enum MemoryMode {
    /// No memory, don't remember values
    case NoMemory
    /// Remember values, but not after the stream ends
    case UntilEnd
    /// Remember values, also after the stream ends
    case AfterEnd
    
    /// Test if this has memory
    func isMemory() -> Bool {
        return self == .UntilEnd || self == .AfterEnd
    }
}



/// The inner type in a FStream that is protected via a Locker
fileprivate class Inner<T> {
    var alive = true
    var ws: [Weak<Listener<T>>] = []
    var ss: [Strong<Listener<T>>] = []
    var memoryMode: MemoryMode
    var lastValue: T? = nil
    
    init(_ memoryMode: MemoryMode) {
        self.memoryMode = memoryMode
    }
    
    /// Weakly subscribe to values passing this instance
    func subscribeWeak(onvalue: @escaping (T?) -> Void) -> Peg {
        if !alive {
            if self.memoryMode == .AfterEnd {
                onvalue(self.lastValue)
            } else {
                onvalue(nil)
            }
            return Peg(l: 0 as AnyObject) // fake peg
        }
        let l = Listener(closure: onvalue)
        let w = Weak(value: l)
        let p = Peg(l: l)
        self.ws.append(w)
        if self.memoryMode.isMemory() && self.lastValue != nil {
            onvalue(self.lastValue)
        }
        return p
    }
    
    /// Strongly subscribe to values passing this instance
    func subscribeStrong(peg: Peg?, onvalue: @escaping (T?) -> Void) -> Strong<Listener<T>> {
        if !alive {
            if self.memoryMode == .AfterEnd {
                onvalue(self.lastValue)
            } else {
                onvalue(nil)
            }
            return Strong(value: nil)
        }
        let l = Listener(closure: onvalue)
        l.extra = peg as AnyObject
        let s = Strong(value: l)
        if self.memoryMode.isMemory() && self.lastValue != nil {
            onvalue(self.lastValue)
        }
        self.ss.append(s)
        return s
    }
    
    /// Update that also runs imitators after the update finishes.
    func updateAndImitate(_ t: T?) {
        // normal update
        self.update(t)
        
        // any imitator that have been gathered during the update is executed now
        // sync with the same update. keep doing this until there are no more
        // imitators added.
        while true {
            var todo: [Imitation] = []
            // this is inside a lock, we must get the value out and release
            // the lock since the imitator run might need the lock to add
            // more imitators (i.e. avoid deadlock).
            imitations.withValue() {
                $0.withValue() {
                    todo = $0
                    $0 = []
                }
            }
            if todo.isEmpty {
                // nothing to do
                break
            } else {
                // run all imitators
                todo.forEach() { $0() }
            }
        }
    }
    
    /// Update a new value to the stream. `nil` indicates the end of the stream
    func update(_ t: T?) {
        if !alive {
            return
        }
        
        // strong subscribers get the value first, only
        // keep listeners that haven't unsubscribed
        self.ss = self.ss.filter() {
            guard let s = $0.get() else {
                return false
            }
            s.apply(t: t)
            return true
        }
        
        // weak subscribers second, only keep the
        // ones that are still there.
        self.ws = self.ws.filter() {
            guard let w = $0.get() else {
                return false
            }
            w.apply(t: t)
            return true
        }
        
        // nil indicates the end of the stream
        if t == nil {
            alive = false
            // release all listeners
            self.ws = []
            self.ss = []
            if self.memoryMode != .AfterEnd {
                self.lastValue = nil
            }
        } else {
            if self.memoryMode.isMemory() {
                self.lastValue = t
            }
        }
    }
}



/// A listener is just a closure here wrapped in a class so
/// we can in turn put it inside a `Weak` or `Strong`.
fileprivate class Listener<T> {
    let closure: (T?) -> Void
    // if we need to hold a reference to something more :)
    var extra: AnyObject?
    init(closure: @escaping (T?) -> Void) {
        self.closure = closure
    }
    func apply(t: T?) {
        self.closure(t)
    }
}

/// Untyped strong reference to something. We use it to keep strong
/// references to a `Listener<T>` so that we can weakly subscribe
/// to a parent stream and make the lifetime of the ARC "live" in
/// the child object.
fileprivate struct Peg {
    var parent: AnyObject? = nil
    var l: AnyObject?
    
    init(l: AnyObject) {
        self.l = l
    }
    
    init(pegs: [Peg]) {
        self.l = pegs as AnyObject
    }
}



/// Protocol to make `Weak` and `Strong` behave the same.
fileprivate protocol Get {
    associatedtype W: AnyObject
    func get() -> W?
}



/// Weak reference to some object
fileprivate class Weak<W: AnyObject> : Get {
    weak var value : W?
    init(value: W) {
        self.value = value
    }
    func get() -> W? {
        return value
    }
}



/// Strong reference to some object
fileprivate class Strong<W: AnyObject> : Get {
    var value: W?
    init(value: W?) {
        self.value = value
    }
    func get() -> W? {
        return value
    }
    func clear() {
        self.value = nil
    }
}

/// Dummy function to let us ignore values that are not read.
func ignore<T>(_ _x: T) {}



// MARK: ABANDON ALL HOPE YE WHO ENTERS HERE!

/// Combine a number of streams and emit values when any of them emit a value.
///
/// All streams must have had at least one value before anything happens.
public func combine<A, B>(_ a: FStream<A>, _ b: FStream<B>) -> FStream<(A, B)> {
    let stream = FStream<(A, B)>(memoryMode: .NoMemory)
    let inner = stream.inner
    var va: A? = nil
    var vb: B? = nil
    let emit = { inner.withValue() {
        if let a = va {
            if let b = vb {
                $0.update((a, b))
            }
        }
        }
    }
    var count = 2
    let pegs: [Peg] = [
        a.subscribeInner() {
            if let t = $0 {
                va = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        b.subscribeInner() {
            if let t = $0 {
                vb = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        }
    ]
    stream.parent = Peg(pegs: pegs)
    return stream
}

/// Combine a number of streams and emit values when any of them emit a value.
///
/// All streams must have had at least one value before anything happens.
public func combine<A, B, C>(_ a: FStream<A>, _ b: FStream<B>, _ c: FStream<C>) -> FStream<(A, B, C)> {
    let stream = FStream<(A, B, C)>(memoryMode: .NoMemory)
    let inner = stream.inner
    var va: A? = nil
    var vb: B? = nil
    var vc: C? = nil
    let emit = { inner.withValue() {
        if let a = va {
            if let b = vb {
                if let c = vc {
                    $0.update((a, b, c))
                }
            }
        }
        }
    }
    var count = 3
    let pegs: [Peg] = [
        a.subscribeInner() {
            if let t = $0 {
                va = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        b.subscribeInner() {
            if let t = $0 {
                vb = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        c.subscribeInner() {
            if let t = $0 {
                vc = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        }
    ]
    stream.parent = Peg(pegs: pegs)
    return stream
}

/// Combine a number of streams and emit values when any of them emit a value.
///
/// All streams must have had at least one value before anything happens.
public func combine<A, B, C, D>(_ a: FStream<A>, _ b: FStream<B>, _ c: FStream<C>, _ d: FStream<D>) -> FStream<(A, B, C, D)> {
    let stream = FStream<(A, B, C, D)>(memoryMode: .NoMemory)
    let inner = stream.inner
    var va: A? = nil
    var vb: B? = nil
    var vc: C? = nil
    var vd: D? = nil
    let emit = { inner.withValue() {
        if let a = va {
            if let b = vb {
                if let c = vc {
                    if let d = vd {
                        $0.update((a, b, c, d))
                    }
                }
            }
        }
        }
    }
    var count = 4
    let pegs: [Peg] = [
        a.subscribeInner() {
            if let t = $0 {
                va = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        b.subscribeInner() {
            if let t = $0 {
                vb = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        c.subscribeInner() {
            if let t = $0 {
                vc = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        d.subscribeInner() {
            if let t = $0 {
                vd = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        }
    ]
    stream.parent = Peg(pegs: pegs)
    return stream
}

/// Combine a number of streams and emit values when any of them emit a value.
///
/// All streams must have had at least one value before anything happens.
public func combine<A, B, C, D, E>(_ a: FStream<A>, _ b: FStream<B>, _ c: FStream<C>, _ d: FStream<D>, _ e: FStream<E>) -> FStream<(A, B, C, D, E)> {
    let stream = FStream<(A, B, C, D, E)>(memoryMode: .NoMemory)
    let inner = stream.inner
    var va: A? = nil
    var vb: B? = nil
    var vc: C? = nil
    var vd: D? = nil
    var ve: E? = nil
    let emit = { inner.withValue() {
        if let a = va {
            if let b = vb {
                if let c = vc {
                    if let d = vd {
                        if let e = ve {
                            $0.update((a, b, c, d, e))
                        }
                    }
                }
            }
        }
        }
    }
    var count = 5
    let pegs: [Peg] = [
        a.subscribeInner() {
            if let t = $0 {
                va = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        b.subscribeInner() {
            if let t = $0 {
                vb = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        c.subscribeInner() {
            if let t = $0 {
                vc = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        d.subscribeInner() {
            if let t = $0 {
                vd = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        },
        e.subscribeInner() {
            if let t = $0 {
                ve = t
                emit()
            } else {
                count -= 1
                if count == 0 {
                    inner.withValue() { $0.update(nil) }
                }
            }
        }
    ]
    stream.parent = Peg(pegs: pegs)
    return stream
}
