;; SPDX-License-Identifier: MIT
;; What the client does, told to whoever listens: each call's kind (a keyword) and data (a map),
;; once it answered. A visualization follows a REPL this way (clients/jank-viz) with nothing
;; added to what the person types. No listener: nothing.
(ns determinismo.tap)

(def ^:private listeners (atom []))

(defn listen!
  "`f` called with each call's kind and data from now on."
  [f]
  (swap! listeners conj f)
  nil)

(defn tell
  "Tells the listeners, and returns `value` (what the call answers)."
  [kind data value]
  (doseq [f @listeners]
    (f kind data))
  value)
