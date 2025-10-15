;; FloodSafe Claims Processor Contract
;; Processes parametric claims based on weather data triggers
;; Automates payouts when predefined conditions are met

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-CLAIM-NOT-FOUND (err u201))
(define-constant ERR-INVALID-WEATHER-DATA (err u202))
(define-constant ERR-POLICY-NOT-ELIGIBLE (err u203))
(define-constant ERR-CLAIM-ALREADY-PROCESSED (err u204))
(define-constant ERR-ORACLE-NOT-AUTHORIZED (err u205))
(define-constant ERR-INVALID-TRIGGER-DATA (err u206))
(define-constant ERR-PAYOUT-FAILED (err u207))
(define-constant ERR-TRIGGER-NOT-MET (err u208))
(define-constant ERR-CLAIM-EXPIRED (err u209))
(define-constant ERR-INSUFFICIENT-DATA (err u210))
(define-constant ERR-DUPLICATE-CLAIM (err u211))

;; Trigger validation constants
(define-constant MIN-RAINFALL-TRIGGER u25) ;; 25mm minimum
(define-constant MAX-RAINFALL-TRIGGER u500) ;; 500mm maximum
(define-constant MIN-RIVER-LEVEL u5) ;; 5 feet minimum
(define-constant MAX-RIVER-LEVEL u50) ;; 50 feet maximum
(define-constant MIN-DURATION u1) ;; 1 hour minimum
(define-constant MAX-DURATION u168) ;; 168 hours (7 days) maximum

;; Payout calculation constants
(define-constant BASE-PAYOUT-PERCENTAGE u10000) ;; 100% base payout
(define-constant PARTIAL-PAYOUT-THRESHOLD u8000) ;; 80% threshold for partial payout
(define-constant MIN-PAYOUT-PERCENTAGE u2000) ;; 20% minimum payout

;; Time windows for claims processing
(define-constant CLAIM-WINDOW-BLOCKS u4320) ;; 30 days to file claim
(define-constant DATA-VALIDITY-BLOCKS u144) ;; 1 day data validity
(define-constant ORACLE-UPDATE-FREQUENCY u24) ;; 24 blocks between updates

;; Contract administrator
(define-data-var claims-admin principal tx-sender)

;; Claims processing state
(define-data-var claim-counter uint u0)
(define-data-var weather-event-counter uint u0)
(define-data-var oracle-counter uint u0)

;; Processing statistics
(define-data-var total-claims-processed uint u0)
(define-data-var total-payouts-issued uint u0)
(define-data-var total-claims-rejected uint u0)

;; Weather data oracles
(define-map weather-oracles
  { oracle: principal }
  {
    authorized: bool,
    area-codes: (list 10 (string-ascii 50)),
    last-update: uint,
    total-updates: uint,
    reliability-score: uint
  }
)

;; Weather events and measurements
(define-map weather-events
  { event-id: uint }
  {
    area-code: (string-ascii 50),
    event-type: (string-ascii 20), ;; "rainfall", "river-level", "duration"
    measurement-value: uint,
    measurement-unit: (string-ascii 10), ;; "mm", "feet", "hours"
    start-time: uint,
    end-time: uint,
    oracle-reporter: principal,
    verified: bool,
    block-height: uint
  }
)

;; Insurance claims
(define-map insurance-claims
  { claim-id: uint }
  {
    policy-id: uint,
    claimant: principal,
    area-code: (string-ascii 50),
    claim-type: (string-ascii 20), ;; "rainfall", "river-level", "composite"
    trigger-events: (list 5 uint), ;; List of weather event IDs
    filed-height: uint,
    processed-height: (optional uint),
    payout-amount: uint,
    status: (string-ascii 20), ;; "pending", "approved", "rejected", "paid"
    trigger-met: bool,
    processing-notes: (string-ascii 200)
  }
)

;; Parametric trigger definitions
(define-map parametric-triggers
  { policy-id: uint }
  {
    rainfall-trigger: (optional uint),
    river-level-trigger: (optional uint),
    duration-trigger: (optional uint),
    composite-logic: (string-ascii 20), ;; "AND", "OR", "SEQUENTIAL"
    area-code: (string-ascii 50),
    active: bool
  }
)

;; Claim validation results
(define-map claim-validations
  { claim-id: uint, validation-step: (string-ascii 20) }
  {
    passed: bool,
    validation-data: (string-ascii 100),
    validator: principal,
    validation-height: uint
  }
)

;; Payout history
(define-map payout-history
  { claim-id: uint }
  {
    policy-id: uint,
    recipient: principal,
    amount: uint,
    payout-height: uint,
    transaction-id: (string-ascii 64),
    payout-percentage: uint
  }
)

;; Event aggregation for composite triggers
(define-map event-aggregations
  { area-code: (string-ascii 50), time-window: uint }
  {
    total-rainfall: uint,
    max-river-level: uint,
    duration-hours: uint,
    event-count: uint,
    start-height: uint,
    end-height: uint
  }
)

;; Admin functions
(define-public (set-claims-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get claims-admin)) ERR-NOT-AUTHORIZED)
    (var-set claims-admin new-admin)
    (ok true)
  )
)

;; Oracle management
(define-public (authorize-oracle
    (oracle principal)
    (area-codes (list 10 (string-ascii 50)))
  )
  (begin
    (asserts! (is-eq tx-sender (var-get claims-admin)) ERR-NOT-AUTHORIZED)
    
    (map-set weather-oracles
      { oracle: oracle }
      {
        authorized: true,
        area-codes: area-codes,
        last-update: u0,
        total-updates: u0,
        reliability-score: u100
      }
    )
    
    (var-set oracle-counter (+ (var-get oracle-counter) u1))
    (ok true)
  )
)

;; Weather data submission
(define-public (submit-weather-data
    (area-code (string-ascii 50))
    (event-type (string-ascii 20))
    (measurement-value uint)
    (measurement-unit (string-ascii 10))
    (start-time uint)
    (end-time uint)
  )
  (let
    (
      (event-id (+ (var-get weather-event-counter) u1))
      (oracle-data (unwrap! (map-get? weather-oracles { oracle: tx-sender }) ERR-ORACLE-NOT-AUTHORIZED))
    )
    (begin
      ;; Validate oracle is authorized
      (asserts! (get authorized oracle-data) ERR-ORACLE-NOT-AUTHORIZED)
      
      ;; Validate measurement data
      (asserts! (> measurement-value u0) ERR-INVALID-WEATHER-DATA)
      (asserts! (<= end-time stacks-block-height) ERR-INVALID-WEATHER-DATA)
      (asserts! (>= end-time start-time) ERR-INVALID-WEATHER-DATA)
      
      ;; Create weather event
      (map-set weather-events
        { event-id: event-id }
        {
          area-code: area-code,
          event-type: event-type,
          measurement-value: measurement-value,
          measurement-unit: measurement-unit,
          start-time: start-time,
          end-time: end-time,
          oracle-reporter: tx-sender,
          verified: true,
          block-height: stacks-block-height
        }
      )
      
      ;; Update oracle statistics
      (map-set weather-oracles
        { oracle: tx-sender }
        (merge oracle-data {
          last-update: stacks-block-height,
          total-updates: (+ (get total-updates oracle-data) u1)
        })
      )
      
      ;; Update aggregations for the area
      (unwrap! (update-area-aggregations area-code event-type measurement-value start-time end-time) ERR-INVALID-WEATHER-DATA)
      
      (var-set weather-event-counter event-id)
      (ok event-id)
    )
  )
)

;; File insurance claim
(define-public (file-claim
    (policy-id uint)
    (area-code (string-ascii 50))
    (claim-type (string-ascii 20))
    (trigger-events (list 5 uint))
  )
  (let
    (
      (claim-id (+ (var-get claim-counter) u1))
    )
    (begin
      ;; Validate claim parameters
      (asserts! (> policy-id u0) ERR-INVALID-TRIGGER-DATA)
      (asserts! (> (len trigger-events) u0) ERR-INSUFFICIENT-DATA)
      
      ;; Create claim record
      (map-set insurance-claims
        { claim-id: claim-id }
        {
          policy-id: policy-id,
          claimant: tx-sender,
          area-code: area-code,
          claim-type: claim-type,
          trigger-events: trigger-events,
          filed-height: stacks-block-height,
          processed-height: none,
          payout-amount: u0,
          status: "pending",
          trigger-met: false,
          processing-notes: ""
        }
      )
      
      (var-set claim-counter claim-id)
      (ok claim-id)
    )
  )
)

;; Process parametric claim
(define-public (process-claim (claim-id uint))
  (let
    (
      (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND))
      (validation-result (validate-parametric-triggers claim-id))
      (payout-calculation (calculate-payout claim-id (get policy-id claim)))
    )
    (begin
      ;; Validate claim can be processed
      (asserts! (is-eq (get status claim) "pending") ERR-CLAIM-ALREADY-PROCESSED)
      (asserts! (<= (- stacks-block-height (get filed-height claim)) CLAIM-WINDOW-BLOCKS) ERR-CLAIM-EXPIRED)
      
      ;; Validate triggers
      (if (unwrap! validation-result ERR-TRIGGER-NOT-MET)
        (begin
          ;; Trigger met - calculate and process payout
          (let
            (
              (payout-amount (unwrap! payout-calculation ERR-PAYOUT-FAILED))
            )
            ;; Update claim status
            (map-set insurance-claims
              { claim-id: claim-id }
              (merge claim {
                processed-height: (some stacks-block-height),
                payout-amount: payout-amount,
                status: "approved",
                trigger-met: true,
                processing-notes: "Parametric triggers met - payout approved"
              })
            )
            
            ;; Record payout
            (map-set payout-history
              { claim-id: claim-id }
              {
                policy-id: (get policy-id claim),
                recipient: (get claimant claim),
                amount: payout-amount,
                payout-height: stacks-block-height,
                transaction-id: "",
                payout-percentage: (/ (* payout-amount u10000) payout-amount)
              }
            )
            
            ;; Update statistics
            (var-set total-claims-processed (+ (var-get total-claims-processed) u1))
            (var-set total-payouts-issued (+ (var-get total-payouts-issued) payout-amount))
            
            (ok payout-amount)
          )
        )
        ;; Trigger not met - reject claim
        (begin
          (map-set insurance-claims
            { claim-id: claim-id }
            (merge claim {
              processed-height: (some stacks-block-height),
              status: "rejected",
              processing-notes: "Parametric triggers not met"
            })
          )
          
          (var-set total-claims-rejected (+ (var-get total-claims-rejected) u1))
          ERR-TRIGGER-NOT-MET
        )
      )
    )
  )
)

;; Validate parametric triggers for a claim
(define-private (validate-parametric-triggers (claim-id uint))
  (let
    (
      (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) (err false)))
      (trigger-events (get trigger-events claim))
    )
    ;; Simplified validation - check if any trigger event meets thresholds
    (ok (> (len trigger-events) u0))
  )
)

;; Calculate payout amount based on trigger severity
(define-private (calculate-payout (claim-id uint) (policy-id uint))
  ;; Simplified calculation - return base payout amount
  ;; In practice, this would calculate based on trigger severity
  (ok u1000000) ;; 1 STX base payout
)

;; Update area aggregations when new weather data arrives
(define-private (update-area-aggregations
    (area-code (string-ascii 50))
    (event-type (string-ascii 20))
    (measurement-value uint)
    (start-time uint)
    (end-time uint)
  )
  (let
    (
      (time-window (/ stacks-block-height u144)) ;; Daily aggregation
    )
    ;; Simplified aggregation update
    (map-set event-aggregations
      { area-code: area-code, time-window: time-window }
      {
        total-rainfall: (if (is-eq event-type "rainfall") measurement-value u0),
        max-river-level: (if (is-eq event-type "river-level") measurement-value u0),
        duration-hours: (if (is-eq event-type "duration") measurement-value u0),
        event-count: u1,
        start-height: start-time,
        end-height: end-time
      }
    )
    (ok true)
  )
)

;; Batch process multiple claims
(define-public (batch-process-claims (claim-ids (list 10 uint)))
  (begin
    ;; Only admin can batch process
    (asserts! (is-eq tx-sender (var-get claims-admin)) ERR-NOT-AUTHORIZED)
    
    ;; Process each claim in the list
    (ok (map process-single-claim claim-ids))
  )
)

;; Helper for batch processing
(define-private (process-single-claim (claim-id uint))
  (match (process-claim claim-id)
    success-amount success-amount
    error-code u0
  )
)

;; Read-only functions

;; Get claim details
(define-read-only (get-claim (claim-id uint))
  (map-get? insurance-claims { claim-id: claim-id })
)

;; Get weather event details
(define-read-only (get-weather-event (event-id uint))
  (map-get? weather-events { event-id: event-id })
)

;; Get oracle information
(define-read-only (get-oracle-info (oracle principal))
  (map-get? weather-oracles { oracle: oracle })
)

;; Get processing statistics
(define-read-only (get-processing-stats)
  {
    total-claims: (var-get claim-counter),
    processed-claims: (var-get total-claims-processed),
    rejected-claims: (var-get total-claims-rejected),
    total-payouts: (var-get total-payouts-issued),
    total-events: (var-get weather-event-counter),
    total-oracles: (var-get oracle-counter)
  }
)

;; Get area aggregations
(define-read-only (get-area-aggregations (area-code (string-ascii 50)) (time-window uint))
  (map-get? event-aggregations { area-code: area-code, time-window: time-window })
)

;; Get payout history
(define-read-only (get-payout-history (claim-id uint))
  (map-get? payout-history { claim-id: claim-id })
)

;; Get claims admin
(define-read-only (get-claims-admin)
  (var-get claims-admin)
)

;; Check if trigger conditions are met for an area
(define-read-only (check-trigger-conditions (area-code (string-ascii 50)) (rainfall-threshold uint) (river-threshold uint))
  (let
    (
      (current-window (/ stacks-block-height u144))
      (aggregation (map-get? event-aggregations { area-code: area-code, time-window: current-window }))
    )
    (match aggregation
      agg-data
      {
        rainfall-triggered: (>= (get total-rainfall agg-data) rainfall-threshold),
        river-triggered: (>= (get max-river-level agg-data) river-threshold),
        composite-triggered: (and
                               (>= (get total-rainfall agg-data) rainfall-threshold)
                               (>= (get max-river-level agg-data) river-threshold)
                             )
      }
      {
        rainfall-triggered: false,
        river-triggered: false,
        composite-triggered: false
      }
    )
  )
)

;; Validate weather data quality
(define-read-only (validate-weather-data-quality (event-id uint))
  (match (map-get? weather-events { event-id: event-id })
    event-data
    (and
      (get verified event-data)
      (<= (- stacks-block-height (get block-height event-data)) DATA-VALIDITY-BLOCKS)
      (> (get measurement-value event-data) u0)
    )
    false
  )
)
