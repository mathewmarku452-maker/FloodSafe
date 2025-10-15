;; FloodSafe Insurance Pool Contract
;; Manages the collective insurance fund, premium collection, and policy issuance
;; Enables pool contributors to provide capital and earn yield from premiums

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-FUNDS (err u101))
(define-constant ERR-POLICY-NOT-FOUND (err u102))
(define-constant ERR-POLICY-EXPIRED (err u103))
(define-constant ERR-INVALID-AMOUNT (err u104))
(define-constant ERR-INVALID-COVERAGE-AREA (err u105))
(define-constant ERR-POOL-INSUFFICIENT (err u106))
(define-constant ERR-ALREADY-COVERED (err u107))
(define-constant ERR-INVALID-PARAMETERS (err u108))
(define-constant ERR-CONTRIBUTOR-NOT-FOUND (err u109))
(define-constant ERR-WITHDRAWAL-TOO-LARGE (err u110))

;; Pool management constants
(define-constant MIN-POLICY-DURATION u2160) ;; 15 days minimum
(define-constant MAX-POLICY-DURATION u52560) ;; 365 days maximum
(define-constant MIN-CONTRIBUTION u1000000) ;; 1 STX minimum contribution
(define-constant POOL-FEE-BASIS-POINTS u500) ;; 5% pool management fee
(define-constant BASIS-POINTS-DIVISOR u10000)
(define-constant MAX-COVERAGE-RATIO u8000) ;; 80% max coverage of pool

;; Premium calculation constants
(define-constant BASE-PREMIUM-RATE u100) ;; Base rate per 10,000 coverage
(define-constant RISK-MULTIPLIER-LOW u50)
(define-constant RISK-MULTIPLIER-MEDIUM u100)
(define-constant RISK-MULTIPLIER-HIGH u200)

;; Pool administrator
(define-data-var pool-admin principal tx-sender)

;; Pool state variables
(define-data-var total-pool-balance uint u0)
(define-data-var total-coverage-outstanding uint u0)
(define-data-var policy-counter uint u0)
(define-data-var contributor-counter uint u0)

;; Pool statistics
(define-data-var total-premiums-collected uint u0)
(define-data-var total-payouts-made uint u0)
(define-data-var total-policies-issued uint u0)

;; Pool contributors who provide capital
(define-map pool-contributors
  { contributor: principal }
  {
    contribution-amount: uint,
    join-height: uint,
    earned-yield: uint,
    last-yield-claim: uint,
    active: bool
  }
)

;; Insurance policies
(define-map insurance-policies
  { policy-id: uint }
  {
    policyholder: principal,
    coverage-amount: uint,
    premium-paid: uint,
    coverage-area: (string-ascii 50),
    rainfall-trigger: uint, ;; mm of rainfall in 24h
    river-level-trigger: (optional uint), ;; feet above normal
    duration-trigger: (optional uint), ;; hours of sustained conditions
    start-height: uint,
    end-height: uint,
    active: bool,
    claims-paid: uint
  }
)

;; Coverage areas and their risk levels
(define-map coverage-areas
  { area-code: (string-ascii 50) }
  {
    area-name: (string-ascii 100),
    risk-level: uint, ;; 1=low, 2=medium, 3=high
    base-rainfall-trigger: uint,
    base-river-trigger: (optional uint),
    active: bool,
    total-policies: uint,
    total-coverage: uint
  }
)

;; Track premium payments
(define-map premium-payments
  { policy-id: uint, payment-id: uint }
  {
    amount: uint,
    payment-height: uint,
    period-start: uint,
    period-end: uint
  }
)

;; Yield distribution tracking
(define-map yield-distributions
  { contributor: principal, distribution-id: uint }
  {
    amount: uint,
    distribution-height: uint,
    period-start: uint,
    period-end: uint
  }
)

;; Admin functions
(define-public (set-pool-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get pool-admin)) ERR-NOT-AUTHORIZED)
    (var-set pool-admin new-admin)
    (ok true)
  )
)

;; Pool contributor functions
(define-public (contribute-to-pool (amount uint))
  (let
    (
      (contributor-id (+ (var-get contributor-counter) u1))
      (current-balance (var-get total-pool-balance))
    )
    (begin
      ;; Validate contribution
      (asserts! (>= amount MIN-CONTRIBUTION) ERR-INVALID-AMOUNT)
      
      ;; Transfer STX to pool
      (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
      
      ;; Update or create contributor record
      (match (map-get? pool-contributors { contributor: tx-sender })
        existing-contribution
        ;; Update existing contributor
        (map-set pool-contributors
          { contributor: tx-sender }
          (merge existing-contribution {
            contribution-amount: (+ (get contribution-amount existing-contribution) amount),
            active: true
          })
        )
        ;; Create new contributor
        (begin
          (map-set pool-contributors
            { contributor: tx-sender }
            {
              contribution-amount: amount,
              join-height: stacks-block-height,
              earned-yield: u0,
              last-yield-claim: stacks-block-height,
              active: true
            }
          )
          (var-set contributor-counter contributor-id)
        )
      )
      
      ;; Update pool balance
      (var-set total-pool-balance (+ current-balance amount))
      (ok amount)
    )
  )
)

;; Withdraw from pool (with limitations)
(define-public (withdraw-from-pool (amount uint))
  (let
    (
      (contributor-data (unwrap! (map-get? pool-contributors { contributor: tx-sender }) ERR-CONTRIBUTOR-NOT-FOUND))
      (current-pool-balance (var-get total-pool-balance))
      (outstanding-coverage (var-get total-coverage-outstanding))
      (available-for-withdrawal (if (> current-pool-balance outstanding-coverage)
                                    (- current-pool-balance outstanding-coverage)
                                    u0))
      (contributor-share (/ (* (get contribution-amount contributor-data) available-for-withdrawal) current-pool-balance))
      (max-withdrawal (if (<= contributor-share (get contribution-amount contributor-data))
                          contributor-share
                          (get contribution-amount contributor-data)))
    )
    (begin
      ;; Validate withdrawal
      (asserts! (get active contributor-data) ERR-NOT-AUTHORIZED)
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      (asserts! (<= amount max-withdrawal) ERR-WITHDRAWAL-TOO-LARGE)
      
      ;; Transfer STX to contributor
      (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
      
      ;; Update contributor record
      (map-set pool-contributors
        { contributor: tx-sender }
        (merge contributor-data {
          contribution-amount: (- (get contribution-amount contributor-data) amount)
        })
      )
      
      ;; Update pool balance
      (var-set total-pool-balance (- current-pool-balance amount))
      (ok amount)
    )
  )
)

;; Coverage area management (admin only)
(define-public (add-coverage-area
    (area-code (string-ascii 50))
    (area-name (string-ascii 100))
    (risk-level uint)
    (base-rainfall-trigger uint)
    (base-river-trigger (optional uint))
  )
  (begin
    ;; Only admin can add coverage areas
    (asserts! (is-eq tx-sender (var-get pool-admin)) ERR-NOT-AUTHORIZED)
    
    ;; Validate parameters
    (asserts! (and (>= risk-level u1) (<= risk-level u3)) ERR-INVALID-PARAMETERS)
    (asserts! (> base-rainfall-trigger u0) ERR-INVALID-PARAMETERS)
    
    ;; Add coverage area
    (map-set coverage-areas
      { area-code: area-code }
      {
        area-name: area-name,
        risk-level: risk-level,
        base-rainfall-trigger: base-rainfall-trigger,
        base-river-trigger: base-river-trigger,
        active: true,
        total-policies: u0,
        total-coverage: u0
      }
    )
    
    (ok true)
  )
)

;; Purchase insurance policy
(define-public (purchase-policy
    (coverage-amount uint)
    (coverage-area (string-ascii 50))
    (duration-blocks uint)
    (custom-rainfall-trigger (optional uint))
    (custom-river-trigger (optional uint))
  )
  (let
    (
      (policy-id (+ (var-get policy-counter) u1))
      (area-data (unwrap! (map-get? coverage-areas { area-code: coverage-area }) ERR-INVALID-COVERAGE-AREA))
      (rainfall-trigger (default-to (get base-rainfall-trigger area-data) custom-rainfall-trigger))
      (river-trigger (match custom-river-trigger
                       custom-level (some custom-level)
                       (get base-river-trigger area-data)))
      (premium-amount (calculate-premium coverage-amount (get risk-level area-data) duration-blocks))
      (current-pool-balance (var-get total-pool-balance))
      (current-outstanding (var-get total-coverage-outstanding))
    )
    (begin
      ;; Validate policy parameters
      (asserts! (get active area-data) ERR-INVALID-COVERAGE-AREA)
      (asserts! (> coverage-amount u0) ERR-INVALID-AMOUNT)
      (asserts! (and (>= duration-blocks MIN-POLICY-DURATION) (<= duration-blocks MAX-POLICY-DURATION)) ERR-INVALID-PARAMETERS)
      
      ;; Check pool can cover this policy
      (asserts! (>= current-pool-balance premium-amount) ERR-INSUFFICIENT-FUNDS)
      (asserts! (<= (+ current-outstanding coverage-amount) (/ (* current-pool-balance MAX-COVERAGE-RATIO) BASIS-POINTS-DIVISOR)) ERR-POOL-INSUFFICIENT)
      
      ;; Collect premium
      (try! (stx-transfer? premium-amount tx-sender (as-contract tx-sender)))
      
      ;; Create policy
      (map-set insurance-policies
        { policy-id: policy-id }
        {
          policyholder: tx-sender,
          coverage-amount: coverage-amount,
          premium-paid: premium-amount,
          coverage-area: coverage-area,
          rainfall-trigger: rainfall-trigger,
          river-level-trigger: river-trigger,
          duration-trigger: none,
          start-height: stacks-block-height,
          end-height: (+ stacks-block-height duration-blocks),
          active: true,
          claims-paid: u0
        }
      )
      
      ;; Update statistics
      (var-set policy-counter policy-id)
      (var-set total-pool-balance (+ current-pool-balance premium-amount))
      (var-set total-coverage-outstanding (+ current-outstanding coverage-amount))
      (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium-amount))
      (var-set total-policies-issued (+ (var-get total-policies-issued) u1))
      
      ;; Update area statistics
      (map-set coverage-areas
        { area-code: coverage-area }
        (merge area-data {
          total-policies: (+ (get total-policies area-data) u1),
          total-coverage: (+ (get total-coverage area-data) coverage-amount)
        })
      )
      
      (ok policy-id)
    )
  )
)

;; Process payout (called by claims processor)
(define-public (process-payout (policy-id uint) (payout-amount uint))
  (let
    (
      (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR-POLICY-NOT-FOUND))
      (current-pool-balance (var-get total-pool-balance))
      (current-outstanding (var-get total-coverage-outstanding))
      (pool-fee (/ (* payout-amount POOL-FEE-BASIS-POINTS) BASIS-POINTS-DIVISOR))
      (net-payout (- payout-amount pool-fee))
    )
    (begin
      ;; Validate payout
      (asserts! (get active policy) ERR-POLICY-EXPIRED)
      (asserts! (<= stacks-block-height (get end-height policy)) ERR-POLICY-EXPIRED)
      (asserts! (>= current-pool-balance payout-amount) ERR-POOL-INSUFFICIENT)
      (asserts! (<= payout-amount (- (get coverage-amount policy) (get claims-paid policy))) ERR-INVALID-AMOUNT)
      
      ;; Process payout
      (try! (as-contract (stx-transfer? net-payout tx-sender (get policyholder policy))))
      
      ;; Update policy
      (map-set insurance-policies
        { policy-id: policy-id }
        (merge policy {
          claims-paid: (+ (get claims-paid policy) payout-amount),
          active: (< (+ (get claims-paid policy) payout-amount) (get coverage-amount policy))
        })
      )
      
      ;; Update pool statistics
      (var-set total-pool-balance (- current-pool-balance payout-amount))
      (var-set total-coverage-outstanding (- current-outstanding payout-amount))
      (var-set total-payouts-made (+ (var-get total-payouts-made) payout-amount))
      
      (ok payout-amount)
    )
  )
)

;; Premium calculation function
(define-private (calculate-premium (coverage-amount uint) (risk-level uint) (duration-blocks uint))
  (let
    (
      (base-premium (/ (* coverage-amount BASE-PREMIUM-RATE) BASIS-POINTS-DIVISOR))
      (risk-multiplier (if (is-eq risk-level u1)
                           RISK-MULTIPLIER-LOW
                           (if (is-eq risk-level u2)
                               RISK-MULTIPLIER-MEDIUM
                               RISK-MULTIPLIER-HIGH)))
      (duration-factor (/ duration-blocks u2160)) ;; Scale by 15-day periods
      (risk-adjusted-premium (/ (* base-premium risk-multiplier) u100))
      (final-premium (/ (* risk-adjusted-premium duration-factor) u1))
    )
    (if (>= final-premium u10000) final-premium u10000) ;; Minimum premium of 0.01 STX
  )
)

;; Distribute yield to contributors
(define-public (distribute-yield)
  (let
    (
      (pool-balance (var-get total-pool-balance))
      (outstanding-coverage (var-get total-coverage-outstanding))
      (available-yield (if (> pool-balance outstanding-coverage)
                           (/ (- pool-balance outstanding-coverage) u10) ;; Distribute 10% of excess
                           u0))
    )
    (begin
      ;; Only admin can trigger distribution
      (asserts! (is-eq tx-sender (var-get pool-admin)) ERR-NOT-AUTHORIZED)
      (asserts! (> available-yield u0) ERR-INSUFFICIENT-FUNDS)
      
      ;; Note: Simplified version - in practice would iterate through all contributors
      ;; For now, just update the pool balance
      (var-set total-pool-balance (- pool-balance available-yield))
      (ok available-yield)
    )
  )
)

;; Read-only functions

;; Get policy details
(define-read-only (get-policy (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id })
)

;; Get coverage area info
(define-read-only (get-coverage-area (area-code (string-ascii 50)))
  (map-get? coverage-areas { area-code: area-code })
)

;; Get contributor info
(define-read-only (get-contributor-info (contributor principal))
  (map-get? pool-contributors { contributor: contributor })
)

;; Get pool statistics
(define-read-only (get-pool-stats)
  {
    total-balance: (var-get total-pool-balance),
    total-coverage: (var-get total-coverage-outstanding),
    total-policies: (var-get total-policies-issued),
    total-premiums: (var-get total-premiums-collected),
    total-payouts: (var-get total-payouts-made),
    available-capacity: (- (var-get total-pool-balance) (var-get total-coverage-outstanding))
  }
)

;; Calculate premium quote
(define-read-only (get-premium-quote (coverage-amount uint) (area-code (string-ascii 50)) (duration-blocks uint))
  (match (map-get? coverage-areas { area-code: area-code })
    area-data
    (ok (calculate-premium coverage-amount (get risk-level area-data) duration-blocks))
    ERR-INVALID-COVERAGE-AREA
  )
)

;; Get pool admin
(define-read-only (get-pool-admin)
  (var-get pool-admin)
)

;; Check if policy is active
(define-read-only (is-policy-active (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy
    (and
      (get active policy)
      (< stacks-block-height (get end-height policy))
      (< (get claims-paid policy) (get coverage-amount policy))
    )
    false
  )
)
