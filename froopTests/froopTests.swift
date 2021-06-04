//
//  froopTests.swift
//  froopTests
//
//  Created by martin on 2019-02-23.
//  Copyright © 2019 Lookback Ltd. All rights reserved.
//

@testable import froop
import XCTest

class froopTests: XCTestCase {
    func testPerformanceMap() {
        let sink = FSink<Int>()
        let map = sink.stream().map() { $0 * 2 }
        _ = map.subscribe() { _ in }
        // this poor man's benchmark will only run 10 times. cause that's enough apparently.
        measure {
            sink.update(0)
        }
    }

    func testLinkedChain() {
        // this way we get a scope that deallocates
        // arcs at the end of it. the chain should
        // survive it.
        func makeLinked() -> (FSink<Int>, Collector<Int>) {
            let sink = FSink<Int>()

            let collect = sink.stream()
                .filter() { $0 % 2 == 0 } // there's a risk this intermediary drops
                .map() { $0 * 2 }
                .collect()

            return (sink, collect)
        }

        let (sink, collect) = makeLinked()

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), [0, 4])
    }

    func testFSink() {
        let sink = FSink<Int>()
        let collect = sink.stream().collect()
        DispatchQueue.global().async {
            sink.update(0)
            sink.update(1)
            sink.update(2)
            sink.end()
        }
        XCTAssertEqual(collect.wait(), [0, 1, 2])
    }

    //    func testOf() {
    //        let of = FStream.of(value: 42)
    //        let c1 = of.collect();
    //        let c2 = of.collect();
    //        XCTAssertEqual(c1.take(), [42])
    //        XCTAssertEqual(c2.take(), [42])
    //    }

    //    func testStartWithOf() {
    //
    //        let stream = FStream.of(value: 43)
    //        let collect = stream.startWith(value: 42).collect()
    //
    //        XCTAssertEqual(collect.take(), [43])
    //    }

    //    func testMapMemory() {
    //        let i = FStream.of(value: 42)
    //            .mapTo(value: "Yo")
    //            .remember()
    //        let collect = i.take(amount: 1).collect()
    //        XCTAssertEqual(collect.wait(), ["Yo"])
    //    }

    func testSubscription() {
        let sink = FSink<Int>()

        var r: [Int] = []
        let sub = sink.stream().subscribe() { r.append($0) }

        sink.update(0)
        sink.update(1)
        sub.unsubscribe()
        sink.update(2)

        XCTAssertEqual(r, [0, 1])
    }

    func testSubscribeLink() {
        // this way we get a scope that deallocates
        // arcs at the end of it. the chain should
        // survive it.
        func makeLinked(_ waitFor: DispatchSemaphore) -> FSink<Int> {
            let sink = FSink<Int>()

            sink.stream()
                .map() { $0 * 2 } // there's a risk this intermediary drops
                .subscribe() { _ in // this subscribe adds a strong listener, chain should live
                    waitFor.signal()
                }

            return sink
        }

        let waitFor = DispatchSemaphore(value: 0)
        let sink = makeLinked(waitFor)

        sink.update(1)

        // if the chain dropped, this will just stall
        waitFor.wait()
    }

    func testSubscribeEnd() {
        let sink = FSink<Int>()

        var r: [Int] = []
        sink.stream().subscribeEnd() {
            r.append(42)
        }

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.end()

        XCTAssertEqual(r, [42])
    }

    func testFilter() {
        let sink = FSink<Int>()

        let filt = sink.stream().filter() { $0 % 2 == 0 }
        let collect = filt.collect()

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), [0, 2])
    }

    func testFilterMap() {
        let sink = FSink<Int>()

        let filt = sink.stream().filterMap() { $0 % 2 == 0 ? "\($0)" : nil }
        let collect = filt.collect()

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), ["0", "2"])
    }

    func testImitate() {
        let imitator = FImitator<Int>()
        let collect = imitator.stream().collect()

        let sink = FSink<Int>()
        let stream = sink.stream()

        imitator.imitate(other: stream)

        sink.update(0)
        sink.update(1)
        XCTAssertEqual(collect.take(), [0, 1])

        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), [2])
    }

    func testImitateDealloc() {
        // this way we get a scope that deallocates
        // arcs at the end of it. the chain should
        // survive it.
        func makeLinked() -> (FSink<Int>, Collector<Int>) {
            let imitator = FImitator<Int>()
            let sink = FSink<Int>()

            let trans = imitator.stream().map() { $0 + 40 }

            let mer = merge(trans.take(amount: 1), sink.stream())

            imitator.imitate(other: sink.stream())

            let collect = mer.collect()

            return (sink, collect)
        }

        let (sink, collect) = makeLinked()

        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.take(), [2, 42])
    }

    func testDedupe() {
        let sink = FSink<Int>()

        let deduped = sink.stream().dedupe()
        let collect = deduped.collect()

        sink.update(0)
        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.update(2)
        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), [0, 1, 2])
    }

    func testDedupeBools() {
        let sink = FSink<Bool>()

        let deduped = sink.stream().dedupe()
        let collect = deduped.collect()

        sink.update(false)
        sink.update(false)
        sink.update(true)
        sink.update(true)
        sink.update(false)
        sink.update(false)
        sink.update(true)
        sink.update(true)
        sink.end()

        XCTAssertEqual(collect.wait(), [false, true, false, true])
    }

    func testDedupeBy() {
        class Foo {
            let i: Int
            init(_ i: Int) {
                self.i = i
            }
        }

        let sink = FSink<Foo>()

        let deduped = sink.stream().dedupeBy() { $0.i }
        let collect = deduped
            .map { $0.i }
            .collect()

        sink.update(Foo(0))
        sink.update(Foo(0))
        sink.update(Foo(1))
        sink.update(Foo(2))
        sink.update(Foo(2))
        sink.end()

        XCTAssertEqual(collect.wait(), [0, 1, 2])
    }

    func testDrop() {
        let sink = FSink<Int>()

        let dropped = sink.stream().drop(amount: 2)
        let collect = dropped.collect()

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.update(3)
        sink.update(4)
        sink.end()

        XCTAssertEqual(collect.wait(), [2, 3, 4])
    }

    func testDropWhile() {
        let sink = FSink<Int>()

        let dropped = sink.stream().dropWhile() { $0 % 2 == 1 }
        let collect = dropped.collect()

        sink.update(1)
        sink.update(3)
        sink.update(4)
        sink.update(5)
        sink.update(6)
        sink.end()

        XCTAssertEqual(collect.wait(), [4, 5, 6])
    }

    func testEndWhen() {
        let sink1 = FSink<Int>()
        let sink2 = FSink<String>()

        let ended = sink1.stream().endWhen(other: sink2.stream())
        let collect = ended.collect()

        sink1.update(0)
        sink2.update("ignored")
        sink1.update(1)
        sink2.end() // this ends "ended"
        sink1.update(2) // never seen

        XCTAssertEqual(collect.wait(), [0, 1])
    }

    func testFold() {
        let sink = FSink<Int>()

        let folded = sink.stream().fold("|") { "\($0) + \($1)" }
        let collect = folded.collect()

        sink.update(0)
        sink.update(1)
        sink.end()

        XCTAssertEqual(collect.wait(), ["|", "| + 0", "| + 0 + 1"])
    }

    func testLastValue() {
        let sink = FSink<Int>()

        let last = sink.stream().last()
        let collect = last.collect()

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), [2])
    }

    func testMap() {
        let sink = FSink<Int>()

        let mapped = sink.stream().map() { "\($0)" }
        let collect = mapped.collect()

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), ["0", "1", "2"])
    }

    func testMapTo() {
        let sink = FSink<Int>()

        let mapped = sink.stream().mapTo(value: "42")
        let collect = mapped.collect()

        sink.update(0)
        sink.update(1)
        sink.update(2)
        sink.end()

        XCTAssertEqual(collect.wait(), ["42", "42", "42"])
    }

    func testRemember() {
        let sink = FSink<Int>()

        let rem = sink.stream().remember()

        sink.update(42)

        let c1 = rem.collect()

        sink.update(43)

        let c2 = rem.collect()

        sink.end()

        XCTAssertEqual(c1.wait(), [42, 43])
        XCTAssertEqual(c2.wait(), [43])
    }

    func testSampleCombine() {
        let sink1 = FSink<Int>()
        let sink2 = FSink<String>()

        let comb = sink1.stream().sampleCombine(sink2.stream())

        let collect = comb.collect()

        sink1.update(0) // ignored because no sink2 value
        sink2.update("foo")
        sink1.update(1)
        sink2.update("bar")
        sink1.update(2)
        sink2.end() // sink2 keeps "bar"
        sink1.update(3)

        sink1.end()

        let r: [(Int, String)] = collect.wait()

        // swift tuples are not equatable?!
        XCTAssertEqual(r.map() { $0.0 }, [1, 2, 3])
        XCTAssertEqual(r.map() { $0.1 }, ["foo", "bar", "bar"])
    }

    func testStartWith() {
        let sink = FSink<Int>()

        let collect = sink.stream().startWith(value: 42).collect()

        sink.update(0)
        sink.update(1)
        sink.end()

        XCTAssertEqual(collect.wait(), [42, 0, 1])
    }

    func testTake() {
        let sink = FSink<Int>()

        let taken = sink.stream().take(amount: 2)
        let collect = taken.collect()

        sink.update(0)
        sink.update(1)
        sink.update(2)

        XCTAssertEqual(collect.wait(), [0, 1])
    }

    func testTakeExact() {
        let sink = FSink<Int>()

        let taken = sink.stream().take(amount: 2)
        let collect = taken.collect()

        sink.update(0)
        sink.update(1)

        XCTAssertEqual(collect.wait(), [0, 1])
    }

    func testTakeWhile() {
        let sink = FSink<Int>()

        let taken = sink.stream().takeWhile() { $0 >= 0 }
        let collect = taken.collect()

        sink.update(0)
        sink.update(1)
        sink.update(-2)

        XCTAssertEqual(collect.wait(), [0, 1])
    }

    func testEnd() {
        let sink = FSink<Int>()
        sink.update(0)

        DispatchQueue.global().async {
            sink.end()
        }

        sink.stream().wait()
    }

    func testEndWhenEnded() {
        let sink = FSink<Int>()
        sink.update(0)
        sink.end()

        sink.stream().wait()
    }

    func testFlatten() {
        let sink: FSink<froop.FStream<Int>> = FSink()

        let flat = flatten(nested: sink.stream())
        let collect = flat.collect()

        let sink1 = FSink<Int>()
        sink1.update(0) // missed
        sink.update(sink1.stream())
        sink1.update(1)
        sink1.update(2)
        let sink2 = FSink<Int>()
        sink.update(sink2.stream())
        sink1.update(42) // missed
        sink1.end() // does not end outer
        sink2.update(3)
        sink.end() // doesn't end outer, because sink2 is active
        sink2.update(4)
        sink2.end()

        XCTAssertEqual(collect.wait(), [1, 2, 3, 4])
    }

    func testFlattenMemory() {
        let sink: FSink<froop.FStream<Int>> = FSink()

        let memory$ = sink.stream().remember()

        let sink1 = FSink<Int>()
        sink1.update(0) // missed
        sink.update(sink1.stream())

        let flat = flatten(nested: memory$)
        let collect = flat.collect()

        // the memory$ first value is dispatched async, and there's no guarantee that
        // happens before we reach the update() rows below. this second ought to be
        // enough :)
        sleep(1)

        sink1.update(1)
        sink1.update(2)

        sink.end() // doesn't end outer, because sink2 is active
        sink1.end()

        XCTAssertEqual(collect.wait(), [1, 2])
    }

    func testFlattenSame() {
        struct Foo {
            var stream: FStream<Int>
            var other: Float
        }

        enum FooUpdate {
            case stream(FStream<Int>)
            case other(Float)
        }

        let sinkInt = FSink<Int>()
        let sinkUpdate = FSink<FooUpdate>()

        let foo$ = sinkUpdate.stream().fold(Foo(stream: FStream.never(), other: 0.0)) { prev, upd in
            var next = prev
            switch upd {
            case let .stream(stream):
                next.stream = stream
            case let .other(other):
                next.other = other
            }
            return next
        }

        let int$ = flatten(nested: foo$.map() { $0.stream.remember() })
        sinkUpdate.update(.stream(sinkInt.stream()))
        let coll = int$.collect()

        sinkInt.update(42)

        // what we don't want to see is [42, 42 ,42] repeated for each update of Foo
        sinkUpdate.update(.other(1.0))
        sinkUpdate.update(.other(2.0))
        sinkUpdate.update(.other(3.0))

        sinkInt.update(43)

        sinkUpdate.end()
        sinkInt.end()

        XCTAssertEqual(coll.wait(), [42, 43])
    }

    func testFlattenConcurrently() {
        let sink: FSink<froop.FStream<Int>> = FSink()

        let flat = flattenConcurrently(nested: sink.stream())
        let collect = flat.collect()

        let sink1 = FSink<Int>()
        sink1.update(0) // missed
        sink.update(sink1.stream())
        sink1.update(1)
        sink1.update(2)
        let sink2 = FSink<Int>()
        sink.update(sink2.stream())
        sink1.update(42) // kept!
        sink1.end() // does not end outer
        sink2.update(3)
        sink.end() // does end outer
        sink2.update(4) // missed

        XCTAssertEqual(collect.wait(), [1, 2, 42, 3])
    }

    func testMerge() {
        let sink1 = FSink<Int>()
        let sink2 = FSink<Int>()

        let merg = merge(sink1.stream(), sink2.stream())

        let collect = merg.collect()

        sink1.update(0)
        sink2.update(10)
        sink1.update(1)
        sink1.end() // doesnt end merge
        sink2.update(11)
        sink2.end()

        XCTAssertEqual(collect.wait(), [0, 10, 1, 11])
    }

    func testCombine() {
        let sink1 = FSink<Int>()
        let sink2 = FSink<String>()

        let comb = froop.combine(sink1.stream(), sink2.stream())

        let collect = comb.collect()

        sink1.update(0) // nothing happens
        sink2.update("0") // first value
        sink1.update(1)
        sink2.update("1")
        sink1.end()
        sink2.end()

        let r: [(Int, String)] = collect.wait()

        // swift tuples are not equatable?!
        XCTAssertEqual(r.map() { $0.0 }, [0, 1, 1])
        XCTAssertEqual(r.map() { $0.1 }, ["0", "0", "1"])
    }

    func testCombineNil() {
        let sink1 = FSink<Int?>()
        let sink2 = FSink<String?>()

        let comb = froop.combine(sink1.stream(), sink2.stream())

        let collect = comb.collect()

        sink1.update(nil) // nothing happens
        sink2.update(nil) // first value
        sink2.update("hi") // first value
        sink1.end()
        sink2.end()

        let r: [(Int?, String?)] = collect.wait()

        // swift tuples are not equatable?!
        XCTAssertEqual(r.map() { $0.0 }, [nil, nil])
        XCTAssertEqual(r.map() { $0.1 }, [nil, "hi"])
    }

    func testCombineFromSame() {
        let sink1 = FSink<Int>()
        let stream1 = sink1.stream()

        let stream2 = stream1.map() { "\($0)" }

        let comb = froop.combine(stream1, stream2)

        let collect = comb.collect()

        sink1.update(1) // value from both
        sink1.end()

        let r: [(Int, String)] = collect.wait()

        // swift tuples are not equatable?!
        XCTAssertEqual(r.map() { $0.0 }, [1])
        XCTAssertEqual(r.map() { $0.1 }, ["1"])
    }

    func testCombineWithEnding() {
        let sink1 = FSink<Int>()
        let sink2 = FSink<Int>()
        let sink3 = FSink<Int>()

        let comb = froop.combine(sink1.stream(), sink2.stream(), sink3.stream())

        let collect = comb.collect()

        sink1.update(1)
        sink1.end()
        sink2.update(2)
        sink2.end()
        sink3.update(3)
        sink3.end()

        let r: [(Int, Int, Int)] = collect.wait()

        // swift tuples are not equatable?!
        XCTAssertEqual(r.map() { $0.0 }, [1])
        XCTAssertEqual(r.map() { $0.1 }, [2])
        XCTAssertEqual(r.map() { $0.2 }, [3])
    }
}
