;; SPDX-License-Identifier: MIT
;; The strategy host's own tests: `clojure -M:test` from this directory. Jev is stubbed (no key,
;; no network); each test starts from a fresh per-run state.
(ns strategies-test
  (:require [clojure.test :refer [deftest is testing run-tests]]
            [clojure.string :as str]
            [strategies :as s]))

(defn- candidate [branch label]
  {:branch branch :start_ns 0 :end_ns 10000000000
   :behaviors [{:label label :vtime_ns 1000000000 :new_in_generation 1 :timelines_before 0}]})

(def archive [{:branch 7 :vtime_ns 5000000 :label "y" :timelines 1 :returns 0 :paid 0}
              {:branch 8 :vtime_ns 6000000 :label "z" :timelines 2 :returns 1 :paid 1}])

(defn- fresh! []
  (reset! s/ends {})
  (reset! s/jev-stories {})
  (reset! s/jev-follow-stats {:asked 0 :planned 0 :steered 0 :defaulted 0 :late 0})
  (reset! s/jev-code-seen #{})
  (reset! s/fault-learned {})
  (reset! s/council-learned {}))

;; Model traces as targets: the Raft PoC's stuck leader (Quint's simulator, 3 steps at one node).
(def stuck-itf
  {:states [{(keyword "mbt::actionTaken") "init" (keyword "mbt::nondetPicks") {}}
            {(keyword "mbt::actionTaken") "starting_leadership_transfer"
             (keyword "mbt::nondetPicks") {:n {:tag "Some" :value "raft-node-1"} :t {:tag "Some" :value {:#bigint "5"}}}}
            {(keyword "mbt::actionTaken") "leadership_transfer_timeout"
             (keyword "mbt::nondetPicks") {:n {:tag "Some" :value "raft-node-1"}}}
            {(keyword "mbt::actionTaken") "leadership_transfer_in_progress"
             (keyword "mbt::nondetPicks") {:n {:tag "Some" :value "raft-node-1"}}}]})

(defn- event [name node] {:event name :details {:source node}})

(deftest a-model-trace-is-a-target-of-roles
  (let [file (java.io.File/createTempFile "stuck" ".itf.json")]
    (spit file (cheshire.core/generate-string stuck-itf))
    (is (= [{:action "starting_leadership_transfer" :role 0}
            {:action "leadership_transfer_timeout" :role 0}
            {:action "leadership_transfer_in_progress" :role 0}]
           (:steps (s/target! (str file)))))))

(deftest a-timelines-events-match-the-target-in-order-one-node-a-role
  (let [steps [{:action "starting_leadership_transfer" :role 0}
               {:action "leadership_transfer_timeout" :role 0}
               {:action "leadership_transfer_in_progress" :role 0}]
        run (fn [events] (s/trace-best (reduce #(s/trace-advance steps %1 %2) #{} events)))]
    (testing "in order, at one node: the whole target"
      (is (= 3 (run [(event "starting_leadership_transfer" "raft-node-0")
                     (event "election_won" "raft-node-2")
                     (event "leadership_transfer_timeout" "raft-node-0")
                     (event "leadership_transfer_in_progress" "raft-node-0")]))))
    (testing "another node's timeout is not this transfer's"
      (is (= 1 (run [(event "starting_leadership_transfer" "raft-node-0")
                     (event "leadership_transfer_timeout" "raft-node-1")]))))
    (testing "a later transfer at another node is matched afresh, not stuck on the first's node"
      (is (= 3 (run [(event "starting_leadership_transfer" "raft-node-0")
                     (event "starting_leadership_transfer" "raft-node-1")
                     (event "leadership_transfer_timeout" "raft-node-1")
                     (event "leadership_transfer_in_progress" "raft-node-1")]))))
    (testing "out of order: no further than the order allows"
      (is (= 1 (run [(event "leadership_transfer_timeout" "raft-node-0")
                     (event "starting_leadership_transfer" "raft-node-0")]))))))

(deftest the-tree-returns-just-after-the-furthest-match-and-a-branch-inherits-its-parents
  (reset! s/trace-target {:steps [{:action "starting_leadership_transfer" :role 0}
                                  {:action "leadership_transfer_timeout" :role 0}
                                  {:action "leadership_transfer_in_progress" :role 0}]})
  (reset! s/trace-progress {})
  (let [state (atom {})
        ns 1000000000]
    (s/trace-target-start state {:index 4 :from nil})
    (s/trace-target-event state {:vtime_ns (* 2 ns) :event (event "starting_leadership_transfer" "raft-node-2")})
    (s/trace-target-event state {:vtime_ns (* 5 ns) :event (event "leadership_transfer_timeout" "raft-node-2")})
    (s/trace-target-start (atom {}) {:index 9 :from nil})
    (testing "timeline 4 matched two steps: the return is just after its second"
      (let [[aimed] (s/trace-frontier 1 [(candidate 4 "x") (candidate 9 "y")] 1)]
        (is (= 4 (:branch aimed)))
        (is (= (+ (* 5 ns) 1000) (:vtime_ns aimed)))))
    (testing "a branch from timeline 4 at 6 s starts with its two steps; at 3 s with one"
      (s/trace-target-start (atom {}) {:index 12 :from {:branch 4 :vtime_ns (* 6 ns)}})
      (is (= 2 (s/trace-best (get-in @s/trace-progress [12 :states]))))
      (s/trace-target-start (atom {}) {:index 13 :from {:branch 4 :vtime_ns (* 3 ns)}})
      (is (= 1 (s/trace-best (get-in @s/trace-progress [13 :states])))))
    (testing "half the returns aimed, the rest the explorer's rule"
      (is (= [4 9] (mapv :branch (s/trace-target-returns 1 [(candidate 4 "x") (candidate 9 "y")] 2)))))))

(deftest a-branch-point-whose-children-never-climb-loses-its-turn
  (s/ladder-target! :double-vote)
  (let [ns 1000000000
        late (fn [index at] (s/trace-target-event (atom {:index index})
                                                  {:vtime_ns at :event {:output {:source "raft-node-1" :text "x [DEBUG] node-1: updated currentTerm: term=4"}}}))
        start (fn [index from] (s/trace-target-start (atom {}) {:index index :from from})
                (s/trace-target-event (atom {:index index})
                                      {:vtime_ns 0 :event {:output {:source "raft-node-1" :text "x [DEBUG] node-1: updated currentTerm: term=5"}}}))
        pick (fn [] (:branch (first (s/trace-frontier 1 [(candidate 4 "x") (candidate 5 "y")] 1))))]
    (start 4 nil) (late 4 (* 3 ns))
    (start 5 nil) (late 5 (* 2 ns))
    (testing "both at rung 1: the later one first"
      (is (= 4 (pick))))
    (testing "three children of 4's moment, none climbing: 5's turn"
      (doseq [child [20 21 22]] (s/trace-target-start (atom {}) {:index child :from {:branch 4 :vtime_ns (+ (* 3 ns) 1000)}}))
      (is (= 5 (pick))))
    (testing "a child that climbs counts for its point, not against it"
      (doseq [child [23 24 25]] (s/trace-target-start (atom {}) {:index child :from {:branch 5 :vtime_ns (+ (* 2 ns) 1000)}}))
      (is (= 4 (pick)) "5's three failures equal 4's: the later again")
      (s/trace-target-event (atom {:index 25})
                            {:vtime_ns (* 4 ns) :event {:output {:source "raft-node-1" :text "x [DEBUG] node-1: granted vote: term=4 candidate=10.0.0.5:8300"}}})
      (s/trace-target-event (atom {:index 25})
                            {:vtime_ns (* 5 ns) :event {:output {:source "raft-node-1" :text "x [DEBUG] node-1: granted vote: term=4 candidate=10.0.0.3:8300"}}})
      (is (= 3 (get-in @s/trace-progress [25 :best])) "two candidates in term 4: voted twice")
      (is (= 5 (pick)) "5's point has a climb now: two failures to 4's three"))))

(deftest the-agent-arm-steers-a-timelines-next-step-with-the-options-it-chose
  (reset! s/trace-target {:steps [{:action "starting_leadership_transfer" :role 0}
                                  {:action "leadership_transfer_timeout" :role 0}]})
  (reset! s/trace-progress {7 {:best 1}})
  (reset! s/trace-decisions {"fault" ["pause raft-node-0" "partition raft-node-1 raft-node-2" "kill raft-node-2"]})
  (testing "only options the decisions have are kept"
    (is (= {"leadership_transfer_timeout" {"fault" ["partition raft-node-1 raft-node-2"]}}
           (s/trace-agent-apply! {:steer {:leadership_transfer_timeout {:fault ["partition raft-node-1 raft-node-2" "made up"]}}}))))
  (testing "timeline 7 matched one step: its fault decision takes the timeout's option"
    (with-redefs [rand (constantly 0.0)]
      (let [answer (s/trace-agent-decide (atom {:index 7}) {:decision {:name "fault" :options ["pause raft-node-0" "partition raft-node-1 raft-node-2" "kill raft-node-2"]} :size 1})]
        (is (= "01" (:hex answer))))))
  (testing "as a plan: the timeout's option 7 in 10, the other two 3 in 20 each"
    (is (= {"fault" [[0 1 0.15] [1 2 0.7] [2 3 0.15]]}
           (update-vals (s/trace-agent-plan (atom {:index 7})) (fn [segments] (mapv (fn [[a b w]] [a b (/ (Math/round (* 100 w)) 100.0)]) segments))))))
  (testing "a timeline at no steered step: no plan"
    (reset! s/trace-progress {7 {:best 0}})
    (is (nil? (s/trace-agent-plan (atom {:index 7}))))
    (reset! s/trace-progress {7 {:best 1}}))
  (testing "a decision the agent said nothing of: the injector's own draw"
    (is (nil? (s/trace-agent-decide (atom {:index 7}) {:decision {:name "fault.timing" :options ["a" "b"]} :size 1}))))
  (testing "the prompt names the target and the decisions"
    (let [prompt (s/trace-agent-prompt [])]
      (is (str/includes? prompt "leadership_transfer_timeout"))
      (is (str/includes? prompt "partition raft-node-1 raft-node-2")))))

(deftest a-log-line-is-named-as-determinismo-quint-names-it
  (is (= {:event "election_won" :details {:source "raft-node-1" :term 4 :tally 2}}
         (s/log-step {:source "raft-node-1" :text "2026-11-19T00:00:03.158Z [INFO]  node-1: election won: term=4 tally=2"})))
  (is (= "leadership_transfer_timeout"
         (:event (s/log-step {:source "raft-node-0" :text "2026-11-19T00:00:12.609Z [DEBUG] node-0: leadership transfer timeout"}))))
  (is (= "err_leadership_transfer_timeout_ok_false"
         (:event (s/log-step {:source "raft-node-0" :text "2026-11-19T00:00:12.609Z [DEBUG] node-0: sent response to client: {\"err\":\"leadership transfer timeout\",\"ok\":false}"}))))
  (is (= {:event "election_won" :details {:source "raft-node-2" :level "info" :term 5 :last_leader_id "" :took "1.5ms"}}
         (s/log-step {:source "raft-node-2" :text "level=info msg=\"Election Won!\" term=5 last-leader-id=\"\" took=1.5ms"})))
  (is (= "connection_from" (:event (s/log-step {:source "raft-monitor" :text "connection from 10.0.0.6:56392"}))))
  (is (= {:event "op_data" :details {:source "raft-node-1" :op "apply" :data "aadb6b27"}}
         (s/log-step {:source "raft-node-1" :text "{\"op\":\"apply\",\"data\":\"aadb6b27\"}"})))
  (is (nil? (s/log-step {:source "client" :text "---- 1234 ----"})))
  (testing "an output event matches a target's step by its name and source"
    (let [steps [{:action "leadership_transfer_timeout" :role 0}]]
      (is (= 1 (s/trace-best (s/trace-advance steps #{} (s/named-event {:output {:source "raft-node-0" :text "2026-11-19T00:00:12.609Z [DEBUG] node-0: leadership transfer timeout"}}))))))))

(defn- line [source text] (s/named-event {:output {:source source :text (str "2026-11-19T00:00:01.000Z [DEBUG] " text)}}))

(deftest the-double-votes-ladder-in-the-specs-terms
  (let [fold (fn [lines] (:level (reduce s/ladder-fold {} lines)))]
    (testing "ordinary elections: none of it (their own address is a node's vote for itself)"
      (is (= 0 (fold [(line "raft-node-2" "node-2: granted vote: term=3 candidate=10.0.0.5:8300")
                      (line "raft-node-2" "node-2: vote granted: from=node-2 term=3 tally=1")
                      (line "raft-node-0" "node-0: granted vote: term=3 candidate=10.1.0.5:8300")
                      (line "raft-node-2" "node-2: election won: term=3 tally=2")
                      (line "raft-node-1" "node-1: pre-vote granted: from=node-1 term=4 tally=1")]))))
    (testing "the spec's twoLeadersTest, in the PoC's lines (1416/0 at 38.8 s): 1, 2, 3, 4"
      (let [lines [(line "raft-node-1" "node-1: updated currentTerm: term=24")
                   (line "raft-node-1" "node-1: granted vote: term=24 candidate=10.0.0.5:8300")
                   (line "raft-node-1" "node-1: updated currentTerm: term=23")]
            older (conj lines (line "raft-node-1" "node-1: granted vote: term=23 candidate=10.0.0.3:8300"))]
        (is (= 1 (fold lines)) "its term went back")
        (is (= 2 (fold older)) "it granted node-0's older request: its vote in 24 forgotten")
        (is (= 3 (fold (conj older (line "raft-node-1" "node-1: vote granted: from=node-1 term=24 tally=1"))))
            "standing for 24 again, it votes for itself: its second vote in 24")
        (is (= 4 (fold (conj older (line "raft-node-2" "node-2: election won: term=24 tally=2")
                             (line "raft-node-1" "node-1: election won: term=24 tally=2")))))))
    (testing "its term back, a node pre-campaigning for a term it voted in for another: one step
             from voting twice (its campaign votes for itself unchecked); runs 1422 and 1423 had
             it in 13 of 156 and 7 of 86 timelines, none granting an older vote"
      (let [back [(line "raft-node-1" "node-1: updated currentTerm: term=24")
                  (line "raft-node-1" "node-1: granted vote: term=24 candidate=10.0.0.5:8300")
                  (line "raft-node-1" "node-1: updated currentTerm: term=23")]
            asks (line "raft-node-1" "node-1: asking for pre-vote: term=24 from=node-0 address=raft-node-0:8300")]
        (is (= 2 (fold (conj back asks))))
        (is (= 1 (fold [(line "raft-node-1" "node-1: updated currentTerm: term=24")
                        (line "raft-node-1" "node-1: vote granted: from=node-1 term=24 tally=1")
                        (line "raft-node-1" "node-1: updated currentTerm: term=23")
                        asks]))
            "a term it voted in for itself alone: standing again is no second vote")))))

(deftest a-ladder-targets-progress-and-a-branchs-inheritance
  (s/ladder-target! :double-vote)
  (let [ns 1000000000
        st (atom {})]
    (s/trace-target-start st {:index 4 :from nil})
    (s/trace-target-event st {:vtime_ns (* 2 ns) :event {:output {:source "raft-node-1" :text "x [DEBUG] node-1: updated currentTerm: term=5"}}})
    (s/trace-target-event st {:vtime_ns (* 3 ns) :event {:output {:source "raft-node-1" :text "x [DEBUG] node-1: updated currentTerm: term=4"}}})
    (is (= 1 (get-in @s/trace-progress [4 :best])))
    (is (= (* 3 ns) (get-in @s/trace-progress [4 :best_ns])))
    (testing "a branch after the late write starts at 1; one before it at 0"
      (s/trace-target-start (atom {}) {:index 9 :from {:branch 4 :vtime_ns (* 5 ns)}})
      (s/trace-target-start (atom {}) {:index 10 :from {:branch 4 :vtime_ns (* 2 ns)}})
      (is (= 1 (get-in @s/trace-progress [9 :best])))
      (is (= 0 (get-in @s/trace-progress [10 :best]))))
    (testing "the agent's next step is the rung after the timeline's"
      (reset! s/trace-decisions {"fault" ["pause raft-node-1" "kill raft-node-0"]})
      (reset! s/trace-agent-steer {"older_vote_after_newer" {"fault" ["pause raft-node-1"]}})
      (is (= {"fault" [[0 1 0.7] [1 2 0.3]]}
             (update-vals (s/trace-agent-plan (atom {:index 4}))
                          (fn [segments] (mapv (fn [[a b w]] [a b (/ (Math/round (* 100 w)) 100.0)]) segments))))))))

(deftest rarity-is-the-explorers-whole-rule
  (fresh!)
  (testing "without an archive offered, the frontier alone (explorers before it)"
    (is (= [1] (mapv :branch (s/rarity 3 [(candidate 1 "x")] 3)))))
  (testing "with one, half the returns from the frontier and the rest from the archive"
    (binding [s/*archive* archive]
      (is (= [1 7 8] (mapv :branch (s/rarity 3 [(candidate 1 "x")] 3))))
      (is (= [1 2 7] (mapv :branch (s/rarity 3 [(candidate 1 "x") (candidate 2 "q")] 3)))
          "(3 + 1) / 2 = 2 frontier slots, the archive's best for the third"))))

(deftest rarity-archive2-leans-on-the-archive
  (fresh!)
  (binding [s/*archive* archive]
    (is (= [1 7 8] (mapv :branch (s/rarity-archive2 3 [(candidate 1 "x") (candidate 2 "q")] 3))))))

(deftest jev-archive-never-returns-into-a-failed-timeline
  (fresh!)
  (reset! s/ends {1 {:failing ["a property"]}})
  (with-redefs [s/jev-ask (fn [_ questions]
                            (into {} (for [[id _] questions] [(keyword id) {:type "noul" :noul 0.5}])))]
    (is (= [2] (mapv :branch (s/jev-archive-returns 3 [(candidate 1 "x") (candidate 2 "q")] 3))))
    (binding [s/*archive* archive]
      (is (= #{2 7 8} (set (map :branch (s/jev-archive-returns 3 [(candidate 1 "x") (candidate 2 "q")] 3))))))))

(deftest jev-follow-plans-beside-the-timeline
  (fresh!)
  (let [asked (atom 0)
        options ["restart s1" "crash s2"]]
    (with-redefs [s/jev-ask (fn [_ questions]
                              (swap! asked inc)
                              (Thread/sleep 200) ; Jev's latency: the timeline goes on meanwhile.
                              (into {} (for [[id _] questions]
                                         [(keyword id) {:type "choice" :probabilities {:o0 0.0 :o1 1.0}}])))]
      (binding [s/*pinned* :jev-follow]
        (let [state (atom {})
              decide (fn [ns] (s/answer {:method "random" :pull 1 :size 1 :default "00" :vtime_ns ns
                                         :decision {:name "fault" :options options}} state))]
          (s/answer {:method "branch" :index 0 :seed "aa"} state)
          (s/answer {:method "event" :vtime_ns 1000000000
                     :event {:event "fault" :details {:kind "pause" :node "s3"}}} state)
          (testing "a draw never waits: no plan yet, the default"
            (let [started (System/nanoTime)]
              (is (= {} (decide 1100000000)))
              (is (< (- (System/nanoTime) started) 100000000))))
          (Thread/sleep 400)
          (testing "the plan, arrived in the background, decides"
            (is (= "01" (:hex (decide 1200000000)))))
          (testing "its own choice is no news: no new plan"
            (decide 1300000000)
            (Thread/sleep 300)
            (is (= 1 @asked)))
          (testing "a failure is news: planned again"
            (s/answer {:method "event" :vtime_ns 1400000000
                       :event {:assert {:type "always" :message "lost" :condition false}}} state)
            (decide 1500000000)
            (s/answer {:method "branch_end" :index 0 :outcome "shutdown" :events 1 :failing []} state)
            (s/answer {:method "branch" :index 5 :seed "bb" :from {:branch 0 :vtime_ns 1200000000}} state)
            (Thread/sleep 400)
            (is (= 2 @asked)))
          (testing "what Jev steered is counted"
            (is (= 2 (:asked @s/jev-follow-stats)))
            (is (pos? (:steered @s/jev-follow-stats)))
            (is (pos? (:defaulted @s/jev-follow-stats)))
            (is (= 1 (:late @s/jev-follow-stats)) "the plan asked at 1.5 s landed after its timeline ended"))
          (testing "a child starts from its parent's story up to its moment, and the parent's late plan stays out"
            (is (= [{:at_ns 1000000000 :fault "pause s3"} {:at_ns 1200000000 :chose "crash s2"}]
                   (:story @state))
                "its choice at 1.2 s is in the prefix the child replays")
            (is (= {} (:plan @state)))))))))

(deftest jev-follow-each-timeline-names-its-branch-point
  (fresh!)
  (reset! s/jev-stories {1 [{:at_ns 2000000000 :fault "crash s2"}]
                         2 [{:at_ns 3000000000 :fault "pause s1"}]
                         3 [{:at_ns 1500000000 :failed "lost write"}]})
  (reset! s/ends {3 {:failing ["lost write"]}})
  (let [asked (atom nil)]
    (with-redefs [s/jev-ask (fn [_ questions]
                              (reset! asked (set (keys questions)))
                              ;; Timeline 1 is sure of its fault; timeline 2 hesitates.
                              {:t1 {:type "choice" :probabilities {:o0 0.2 :o1 0.8}}
                               :t2 {:type "choice" :probabilities {:o0 0.4 :o1 0.6}}})]
      (let [chosen (vec (s/jev-follow-returns 4 [(candidate 1 "x") (candidate 2 "q") (candidate 3 "w")] 1))]
        (is (= #{"t1" "t2"} @asked) "a failed timeline is not asked")
        (is (= [1] (mapv :branch chosen)) "the most confident instance's pick")
        (is (= 2000001000 (:vtime_ns (first chosen))) "just after its fault, the moment it named"))
      (binding [s/*archive* archive]
        (is (= [1 2 7] (mapv :branch (s/jev-follow-returns 4 [(candidate 1 "x") (candidate 2 "q")] 3)))
            "half the returns its instances' picks, the rest the explorer's archive")))))

(deftest jev-follow-reads-coverage-live
  (fresh!)
  (reset! s/jev-code-seen #{})
  (binding [s/*pinned* :jev-follow]
    (let [state (atom {})
          covered (fn [ns line] (s/answer {:method "event" :vtime_ns ns
                                          :event {:event "coverage" :details {:name line}}} state))]
      (is (some #{"coverage"} (:wants (s/answer {:method "hello" :protocol 1 :exploration_seed "01" :run_url "probe"} state))))
      (s/answer {:method "branch" :index 0 :seed "aa"} state)
      (covered 1000 "line main.go:112")
      (covered 2000 "line main.go:112")
      (is (= [{:at_ns 1000 :reached "line main.go:112"}] (:story @state)) "a line reached first, once")
      (s/answer {:method "branch" :index 1 :seed "bb"} state)
      (covered 3000 "line main.go:112")
      (is (empty? (:story @state)) "another timeline reaching it later: nothing new")
      (is (zero? (#'s/news-count [{:reached "x"} {:chose "y"}])) "coverage is context, not news"))))

(deftest evolve-follows-the-latest-proposal-that-passed
  (fresh!)
  (reset! s/evolved nil)
  (reset! s/evolutions [])
  (testing "the explorer's rule until a proposal passes"
    (is (= [1] (mapv :branch (s/evolve-returns 3 [(candidate 1 "x")] 3)))))
  (swap! s/strategies assoc :claude-test {:returns (fn [_ _ _] [{:branch 9 :vtime_ns 5 :reason "claude: test"}])})
  (with-redefs [s/propose-strategy! (fn [_] :claude-test)]
    (is (= :claude-test (s/evolve! "http://x/runs/1"))))
  (testing "then the proposal's"
    (is (= [9] (mapv :branch (s/evolve-returns 3 [(candidate 1 "x")] 3)))))
  (with-redefs [s/propose-strategy! (fn [_] "no (fn ...) form in the answer")]
    (s/evolve! "http://x/runs/1"))
  (testing "a refused proposal leaves the last good one"
    (is (= :claude-test @s/evolved))
    (is (= [true false] (mapv :taken @s/evolutions)))))

(deftest learn-credits-the-kinds-that-pay
  (fresh!)
  (reset! s/learned {})
  (reset! s/learn-chosen {})
  (reset! s/run-failed #{})
  (reset! s/starts {})
  (is (= "[ERROR] node-# failed to install snapshot #" (s/moment-kind "[ERROR] node-2 failed to install snapshot 17")))
  (let [snapshot {:branch 1 :start_ns 0 :end_ns 10000000000
                  :behaviors [{:label "[ERROR] node-2 failed to install snapshot 17" :vtime_ns 1000000000 :new_in_generation 1}]}
        election {:branch 2 :start_ns 0 :end_ns 10000000000
                  :behaviors [{:label "node-1 election timeout 3" :vtime_ns 1000000000 :new_in_generation 1}]}
        first-pick (vec (s/learn-returns 1 [snapshot election] 2))]
    (is (= #{1 2} (set (map :branch first-pick))) "nothing learned: both kinds tried")
    ;; Branch 10 from the snapshot moment failed a property anew; branch 11 from the election did not.
    (reset! s/starts {10 {:from {:branch 1 :vtime_ns 1000001000}} 11 {:from {:branch 2 :vtime_ns 1000001000}}})
    (s/learn-end nil {:index 10 :failing ["lost write"]})
    (s/learn-end nil {:index 11 :failing []})
    (is (= {:tries 1 :paid 1.0} (get @s/learned "[ERROR] node-# failed to install snapshot #"))
        "the run's first failure of a property: a whole point")
    (is (= {:tries 1 :paid 0.0} (get @s/learned "node-# election timeout #")))
    (testing "next time, the kind that paid first"
      (is (= [1] (mapv :branch (s/learn-returns 2 [election snapshot] 1)))))
    (testing "a failure the parent already had pays nothing"
      (reset! s/ends {1 {:failing ["lost write"]}})
      (reset! s/starts {12 {:from {:branch 1 :vtime_ns 1000001000}}})
      (s/learn-end nil {:index 12 :failing ["lost write"]})
      (is (= {:tries 2 :paid 1.0} (get @s/learned "[ERROR] node-# failed to install snapshot #"))))
    (testing "anew against its parent but already found in the run: a quarter"
      (reset! s/ends {2 {:failing []}})
      (reset! s/starts {13 {:from {:branch 2 :vtime_ns 1000001000}}})
      (s/learn-end nil {:index 13 :failing ["lost write"]})
      (is (= {:tries 2 :paid 0.25} (get @s/learned "node-# election timeout #"))))))

(deftest mix-splits-the-generation-and-learns-whose-picks-pay
  (fresh!)
  (reset! s/mix-record {})
  (reset! s/mix-chosen {})
  (reset! s/learned {})
  (reset! s/learn-chosen {})
  (reset! s/run-failed #{})
  (reset! s/starts {})
  (reset! s/evolved nil)
  (with-redefs [s/jev-ask (fn [_ questions]
                            (into {} (for [[id _] questions] [(keyword id) {:type "noul" :noul 0.5}])))]
    (let [cands [(candidate 1 "x") (candidate 2 "q") (candidate 3 "w")]
          chosen (vec (s/mix-returns 1 cands 3))]
      (is (= 3 (count chosen)))
      (is (every? #(re-find #"^mix\[" (:reason %)) chosen) "each pick names its member")
      (is (= 3 (count (set (map (juxt :branch :vtime_ns) chosen)))) "no moment twice")
      ;; The pick of whichever member took branch 2's moment found a property new to the run.
      (let [[[at member]] (filter (fn [[[b _] _]] (= 2 b)) @s/mix-chosen)]
        (reset! s/starts {20 {:from {:branch (first at) :vtime_ns (second at)}}})
        (s/mix-end nil {:index 20 :failing ["lost write"]})
        (is (= 1.0 (:paid (get @s/mix-record member))))))))

(deftest council-judges-every-candidate-with-all-of-them
  (fresh!)
  (reset! s/council-learned {"node-# election timeout #" {:tries 4 :paid 3.0}})
  (reset! s/learned {}) ; :learn's record is not the council's.
  (reset! s/learn-chosen {})
  (reset! s/council-weights {:rarity 1.0 :jev 1.0 :learn 1.0})
  (reset! s/council-boosts {})
  (reset! s/council-decisions [])
  (let [snapshot {:branch 1 :start_ns 0 :end_ns 10000000000
                  :behaviors [{:label "[ERROR] node-2 failed to install snapshot 17" :vtime_ns 1000000000 :new_in_generation 1}]}
        election {:branch 2 :start_ns 0 :end_ns 10000000000
                  :behaviors [{:label "node-1 election timeout 3" :vtime_ns 1000000000 :new_in_generation 1}]}]
    (with-redefs [s/jev-ask (fn [_ questions]
                              ;; Jev prefers the snapshot moment; learn's record prefers elections.
                              (into {} (for [[id q] questions]
                                         [(keyword id) {:type "noul" :noul (if (re-find #"snapshot" (:instructions q)) 0.6 0.2)}])))]
      (let [chosen (vec (s/council-returns 1 [snapshot election] 1))]
        (is (= 1 (count chosen)))
        (is (re-find #"rarity .*Jev .*learn .*Claude" (:reason (first chosen))) "every part named in its reason")
        (is (= [1] (mapv :branch chosen)) "Jev's 0.6 against 0.2 outweighs learn's 0.78 against 0.6"))
      (testing "Claude's review moves the weights and boosts"
        (is (true? (#'s/council-apply! "Here: {\"weights\": {\"jev\": 0.1, \"learn\": 2.5}, \"boost\": {\"election\": 3}}")))
        (is (= 0.1 (:jev @s/council-weights)))
        (is (= [2] (mapv :branch (s/council-returns 2 [snapshot election] 1))) "now the election's kind leads")
        (is (false? (#'s/council-apply! "no json here")) "an answer without JSON changes nothing")))))

(deftest council-decides-faults-together-and-credits-them
  (fresh!)
  ;; Both kinds tried six times: the crash paid five, the pause none.
  (reset! s/fault-learned {"crash raft-node-#" {:tries 6 :paid 5.0} "pause raft-node-#" {:tries 6 :paid 0.0}})
  (reset! s/council-weights {:rarity 1.0 :jev 1.0 :learn 3.0})
  (reset! s/council-boosts {})
  (reset! s/run-failed #{})
  (reset! s/starts {})
  (binding [s/*pinned* :council]
    (let [state (atom {})
          options ["pause raft-node-1" "crash raft-node-2"]]
      (s/answer {:method "branch" :index 0 :seed "aa"} state)
      (with-redefs [s/jev-follow-plan! (fn [_ _] nil)] ; No plan yet: the learned payoffs alone.
        (let [draws (frequencies (for [_ (range 200)]
                                   (:hex (s/answer {:method "random" :pull 1 :size 1 :default "00" :vtime_ns 1000
                                                    :decision {:name "fault" :options options}} state))))]
          (is (> (get draws "01" 0) 150) "the crash, whose kind paid 5 of 6, drawn most")))
      (testing "the timeline's end credits the faults it chose itself"
        (s/answer {:method "branch_end" :index 0 :outcome "shutdown" :events 1 :failing ["lost write"]} state)
        (is (= 7 (:tries (get @s/fault-learned "crash raft-node-#"))) "a kind chosen in it, credited once")
        (is (= 6.0 (- (:paid (get @s/fault-learned "crash raft-node-#")) 0.0)) "a whole point: the run's first failure")
        (is (<= 6 (:tries (get @s/fault-learned "pause raft-node-#")) 7))))))

(deftest council-hears-each-timeline-s-own-story
  (fresh!)
  (reset! s/learned {})
  (reset! s/learn-chosen {})
  (reset! s/council-weights {:rarity 1.0 :jev 1.0 :learn 1.0})
  (reset! s/council-boosts {})
  (reset! s/council-decisions [])
  ;; Timeline 3 reached nothing new, but its own story holds a crash, a fault no other timeline was given.
  (reset! s/jev-stories {3 [{:at_ns 2000000000 :fault "crash raft-node-2"} {:at_ns 3000000000 :chose "crash raft-node-2"}]
                         4 [{:at_ns 2000000000 :fault "pause raft-node-1"}]})
  (let [quiet {:branch 3 :start_ns 0 :end_ns 10000000000 :behaviors []}
        common {:branch 4 :start_ns 0 :end_ns 10000000000
                :behaviors [{:label "node-1 Applied block 4" :vtime_ns 1000000000 :new_in_generation 9}]}
        asked (atom nil)]
    (with-redefs [s/jev-ask (fn [context questions]
                              (reset! asked context)
                              (into {} (for [[id q] questions]
                                         [(keyword id) {:type "noul" :noul (if (re-find #"crash" (:instructions q)) 0.7 0.3)}])))]
      (let [chosen (vec (s/council-returns 1 [quiet common] 1))]
        (is (= [3] (mapv :branch chosen)) "the crash in timeline 3's story, rarer and Jev's pick")
        (is (re-find #"council: story, just after the fault crash" (:reason (first chosen))))
        (is (= 3 (count (:moments @asked))) "the frontier's moment and both stories' faults, all asked at once")
        (is (= ["crash raft-node-2 at 2.0 s"]
               (:faults_before (first (filter #(= 3 (:timeline %)) (:moments @asked)))))
            "Jev sees the faults a moment follows")))))

(deftest an-event-fn-ends-a-timeline-with-end-timeline
  (fresh!)
  (swap! s/strategies assoc ::ender {:event (fn [_ {:keys [event]}] (when (= "fault" (:event event)) s/end-timeline))})
  (binding [s/*pinned* ::ender]
    (let [state (atom {})]
      (is (= {:end true} (s/answer {:method "event" :vtime_ns 1 :event {:event "fault"}} state)))
      (is (= {} (s/answer {:method "event" :vtime_ns 2 :event {:event "log"}} state)))))
  (testing "a story kept in a map is no end"
    (binding [s/*pinned* :jev-follow]
      (is (= {} (s/answer {:method "event" :vtime_ns 3 :event {:event "fault" :details {:kind "crash"}}} (atom {})))))))

(deftest council-ender-ends-a-timeline-headed-only-for-known-failures
  (fresh!)
  (reset! s/run-failed #{"lost write"})
  (binding [s/*pinned* :council-ender]
    (let [state (atom {})
          s 1000000000
          failed (fn [message at] {:method "event" :vtime_ns at
                                   :event {:assert {:type "always" :message message :condition false}}})
          tick (fn [at] {:method "event" :vtime_ns at :event {:event "fault" :details {:kind "pause" :node "n1"}}})]
      (s/answer {:method "branch" :index 0 :seed "aa"} state)
      (is (= {} (s/answer (failed "lost write" (* 5 s)) state)) "just failed: not yet")
      (is (= {} (s/answer (tick (* 12 s)) state)) "7 s after: not yet")
      (is (= {:end true} (s/answer (tick (* 16 s)) state)) "11 s after, nothing new reached: ended")
      (testing "a property the run never failed keeps it going"
        (s/answer {:method "branch" :index 1 :seed "bb"} state)
        (s/answer (failed "lost write" (* 5 s)) state)
        (s/answer (failed "stale read" (* 6 s)) state)
        (is (= {} (s/answer (tick (* 30 s)) state))))
      (testing "new code reached keeps it going"
        (s/answer {:method "branch" :index 2 :seed "cc"} state)
        (s/answer (failed "lost write" (* 5 s)) state)
        (s/answer {:method "event" :vtime_ns (* 14 s) :event {:event "coverage" :details {:name "raft.go:991 never seen"}}} state)
        (is (= {} (s/answer (tick (* 16 s)) state)))
        (is (= {:end true} (s/answer (tick (* 25 s)) state)))))))

(deftest jev-and-the-council-decide-when-faults-come
  (fresh!)
  (is (= ["short (under 10.0 s)" "middle (10.0 s to 20.0 s)" "long (over 20.0 s)"]
         (mapv :text (s/timing-options "fault.quiet_ms" 30000))))
  (binding [s/*pinned* :jev-follow]
    (let [state (atom {})
          value (fn [hex] (reduce + (map-indexed (fn [i b] (bit-shift-left (Long/parseLong b 16) (* 8 i)))
                                                (re-seq #".." hex))))]
      (s/answer {:method "branch" :index 0 :seed "aa"} state)
      (with-redefs [s/jev-follow-plan! (fn [_ _] nil)]
        (swap! state assoc :plan {"fault.quiet_ms" {2 1.0}}) ; Jev's plan: wait long.
        (let [reply (s/answer {:method "random" :pull 1 :size 8 :default "0000000000000000" :vtime_ns 1000
                               :decision {:name "fault.quiet_ms" :range 30000}} state)]
          (is (<= 20000 (value (:hex reply)) 29999) "a value in the long third")
          (is (re-find #"long \(over 20.0 s\)" (:reason reply))))
        (is (= "fault.quiet_ms long (over 20.0 s)" (:chose (last (:story @state)))) "the timeline's story says so")
        (is (= {} (s/answer {:method "random" :pull 2 :size 8 :default "0000000000000000" :vtime_ns 2000
                             :decision {:name "fault.wait_ns" :range 2}} state))
            "a range too small to split is the explorer's"))))
  (testing "the council credits a timing third as its own kind"
    (is (= "fault.quiet_ms long (over # s)" (s/decision-kind "fault.quiet_ms" "long (over 20.0 s)")))
    (is (= "crash raft-node-#" (s/decision-kind "fault" "crash raft-node-2")))))

(deftest a-batch-of-events-is-each-event-and-may-end-the-timeline
  (fresh!)
  (swap! s/strategies assoc ::batcher {:event (fn [state {:keys [event vtime_ns]}]
                                                (swap! state update :seen (fnil conj []) vtime_ns)
                                                (when (= "crash" (:event event)) s/end-timeline))})
  (binding [s/*pinned* ::batcher]
    (let [state (atom {})
          item (fn [at kind] {:vtime_ns at :branches 0 :source "n1" :event {:event kind}})]
      (is (= {} (s/answer {:method "events" :events [(item 1 "log") (item 2 "log")]} state)))
      (is (= {:end true} (s/answer {:method "events" :events [(item 3 "crash") (item 4 "log")]} state)))
      (is (= [1 2 3 4] (:seen @state)) "every event of each batch, in order"))))

(deftest a-planning-strategy-plans-from-the-decisions-it-is-told
  (fresh!)
  (reset! s/council-weights {:rarity 1.0 :jev 1.0 :learn 0.0})
  (reset! s/council-boosts {})
  (binding [s/*pinned* :council]
    (let [state (atom {})
          announce (fn [at decision] {:vtime_ns at :branches 0 :source "det-faults" :event {:decision decision}})]
      (s/answer {:method "branch" :index 0 :seed "aa"} state)
      (with-redefs [s/jev-follow-plan! (fn [st _] (swap! st assoc :plan {"fault" {1 0.9 0 0.1} "fault.quiet_ms" {2 1.0}}))]
        (let [reply (s/answer {:method "events"
                               :events [(announce 1000 {:name "fault" :options ["pause raft-node-1" "crash raft-node-2"]})
                                        (announce 2000 {:name "fault.quiet_ms" :range 30000})]} state)
              _ (is (= [[0 1 1.0] [1 2 1.0]] (get-in reply [:plan "fault"])) "before Jev's plan: even (learn's weight 0 here)")
              reply (s/answer {:method "events" :events []} state)] ; Jev's plan came meanwhile.
          (is (= [[0 1 0.1] [1 2 0.9]] (get-in reply [:plan "fault"])) "Jev's weights per option, as segments")
          (is (= [[20000 30000 1.0]] (get-in reply [:plan "fault.quiet_ms"])) "a timing third as its range")))
      (testing "what the plan drew is the timeline's own choice"
        (s/answer {:method "events"
                   :events [{:vtime_ns 3000 :branches 0 :source "det-faults"
                             :event {:event "planned" :details {:value 25000 :decision {:name "fault.quiet_ms" :range 30000}}}}
                            {:vtime_ns 3100 :branches 0 :source "det-faults"
                             :event {:event "planned" :details {:value 1 :decision {:name "fault" :options ["pause raft-node-1" "crash raft-node-2"]}}}}]}
                  state)
        (is (= ["fault.quiet_ms long (over 20.0 s)" "crash raft-node-2"] (keep :chose (:story @state))))))))

(deftest a-run-starts-whatever-the-counters-hold
  (fresh!)
  (reset! s/jev-follow-stats {}) ; As a hand reset leaves them.
  (binding [s/*pinned* :council]
    (is (= "clojure/council" (:name (s/answer {:method "hello" :protocol 1 :exploration_seed "01"
                                               :run_url "http://127.0.0.1:7878/runs/9"} (atom {}))))
        "the hello answers (a counter read as a number failed it, and the explorer stopped: BadPluginReply)")))

(deftest claude-s-loops-start-once-per-run
  (let [started (atom 0)]
    (with-redefs [s/http-json (fn [_] (swap! started inc) {:state "ended"})]
      (s/stop-evolving!)
      (reset! s/evolving-run nil)
      (s/evolve-every! "http://h/runs/1" 1)
      (let [first-loop @s/evolving]
        (dotimes [_ 3] (s/evolve-every! "http://h/runs/1" 1)) ; Every worker's hello.
        (is (identical? first-loop @s/evolving) "the same loop: its timer goes on")
        (s/evolve-every! "http://h/runs/2" 1)
        (is (not (identical? first-loop @s/evolving)) "another run, another loop"))
      (s/stop-evolving!)
      (s/stop-council-review!)
      (reset! s/council-reviewing-run nil)
      (s/council-review-every! "http://h/runs/1" 1)
      (let [first-loop @s/council-reviewing]
        (s/council-review-every! "http://h/runs/1" 1)
        (is (identical? first-loop @s/council-reviewing)))
      (s/stop-council-review!))))

(deftest timeline-reads-an-ended-timelines-compressed-events-and-a-running-ones-plain
  (let [dir (.toFile (java.nio.file.Files/createTempDirectory "events" (make-array java.nio.file.attribute.FileAttribute 0)))
        lines "{\"seq\":1,\"event\":{\"name\":\"a\"}}\n{\"seq\":2,\"event\":{\"name\":\"b\"}}\n"]
    (reset! s/events-dir (.getPath dir))
    (with-open [out (com.github.luben.zstd.ZstdOutputStream. (java.io.FileOutputStream. (java.io.File. dir "branch-3.jsonl.zst")))]
      (.write out (.getBytes lines "UTF-8")))
    (spit (java.io.File. dir "branch-4.jsonl") lines)
    (is (= [1 2] (map :seq (s/timeline 3))) "ended: its .jsonl.zst")
    (is (= ["a" "b"] (map (comp :name :event) (s/timeline 4))) "running: its plain .jsonl")))

(defn -main [& _]
  (let [{:keys [fail error]} (run-tests 'strategies-test)]
    (shutdown-agents)
    (System/exit (if (zero? (+ fail error)) 0 1))))
