;; BITCOIN STACKCHAIN: STAKING & GOVERNANCE PROTOCOL
;;
;; A decentralized protocol for staking STX tokens with tiered rewards and
;; on-chain governance, designed for seamless operation on the Stacks Layer 2
;; network with Bitcoin security and compliance.
;;

;; TOKEN DEFINITIONS

(define-fungible-token ANALYTICS-TOKEN u0)

;; CONSTANTS

(define-constant CONTRACT-OWNER tx-sender)

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INVALID-PROTOCOL (err u1001))
(define-constant ERR-INVALID-AMOUNT (err u1002))
(define-constant ERR-INSUFFICIENT-STX (err u1003))
(define-constant ERR-COOLDOWN-ACTIVE (err u1004))
(define-constant ERR-NO-STAKE (err u1005))
(define-constant ERR-BELOW-MINIMUM (err u1006))
(define-constant ERR-PAUSED (err u1007))

;; DATA VARIABLES

;; Contract state variables
(define-data-var contract-paused bool false)
(define-data-var emergency-mode bool false)
(define-data-var stx-pool uint u0)

;; Reward and staking parameters
(define-data-var base-reward-rate uint u500) ;; 5% base rate (100 = 1%)
(define-data-var bonus-rate uint u100) ;; 1% bonus for longer staking
(define-data-var minimum-stake uint u1000000) ;; Minimum stake amount (1 STX)
(define-data-var cooldown-period uint u1440) ;; 24 hour cooldown in blocks
(define-data-var proposal-count uint u0)

;; DATA MAPS

;; Governance proposals storage
(define-map Proposals
  { proposal-id: uint }
  {
    creator: principal,
    description: (string-utf8 256),
    start-block: uint,
    end-block: uint,
    executed: bool,
    votes-for: uint,
    votes-against: uint,
    minimum-votes: uint,
  }
)

;; User positions and account data
(define-map UserPositions
  principal
  {
    total-collateral: uint,
    total-debt: uint,
    health-factor: uint,
    last-updated: uint,
    stx-staked: uint,
    analytics-tokens: uint,
    voting-power: uint,
    tier-level: uint,
    rewards-multiplier: uint,
  }
)

;; Active staking positions
(define-map StakingPositions
  principal
  {
    amount: uint,
    start-block: uint,
    last-claim: uint,
    lock-period: uint,
    cooldown-start: (optional uint),
    accumulated-rewards: uint,
  }
)

;; Tier system configuration
(define-map TierLevels
  uint
  {
    minimum-stake: uint,
    reward-multiplier: uint,
    features-enabled: (list 10 bool),
  }
)

;; PUBLIC FUNCTIONS - ADMIN

;; Initializes the contract and sets up the tier levels
(define-public (initialize-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    ;; Set up tier levels
    (map-set TierLevels u1 {
      minimum-stake: u1000000, ;; 1M uSTX (1 STX)
      reward-multiplier: u100, ;; 1x
      features-enabled: (list true false false false false false false false false false),
    })
    (map-set TierLevels u2 {
      minimum-stake: u5000000, ;; 5M uSTX (5 STX)
      reward-multiplier: u150, ;; 1.5x
      features-enabled: (list true true true false false false false false false false),
    })
    (map-set TierLevels u3 {
      minimum-stake: u10000000, ;; 10M uSTX (10 STX)
      reward-multiplier: u200, ;; 2x
      features-enabled: (list true true true true true false false false false false),
    })
    (ok true)
  )
)

;; Pauses the contract, disabling certain functions
(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set contract-paused true)
    (ok true)
  )
)

;; Resumes the contract, re-enabling certain functions
(define-public (resume-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set contract-paused false)
    (ok true)
  )
)

;; PUBLIC FUNCTIONS - STAKING

;; Allows users to stake STX tokens with an optional lock period
(define-public (stake-stx
    (amount uint)
    (lock-period uint)
  )
  (let ((current-position (default-to {
      total-collateral: u0,
      total-debt: u0,
      health-factor: u0,
      last-updated: u0,
      stx-staked: u0,
      analytics-tokens: u0,
      voting-power: u0,
      tier-level: u0,
      rewards-multiplier: u100,
    }
      (map-get? UserPositions tx-sender)
    )))
    ;; Validate input parameters
    (asserts! (is-valid-lock-period lock-period) ERR-INVALID-PROTOCOL)
    (asserts! (not (var-get contract-paused)) ERR-PAUSED)
    (asserts! (>= amount (var-get minimum-stake)) ERR-BELOW-MINIMUM)
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    ;; Calculate tier level and multiplier
    (let (
        (new-total-stake (+ (get stx-staked current-position) amount))
        (tier-info (get-tier-info new-total-stake))
        (lock-multiplier (calculate-lock-multiplier lock-period))
      )
      ;; Update staking position
      (map-set StakingPositions tx-sender {
        amount: amount,
        start-block: stacks-block-height,
        last-claim: stacks-block-height,
        lock-period: lock-period,
        cooldown-start: none,
        accumulated-rewards: u0,
      })
      ;; Update user position with new tier info
      (map-set UserPositions tx-sender
        (merge current-position {
          stx-staked: new-total-stake,
          tier-level: (get tier-level tier-info),
          rewards-multiplier: (* (get reward-multiplier tier-info) lock-multiplier),
        })
      )
      ;; Update STX pool
      (var-set stx-pool (+ (var-get stx-pool) amount))
      (ok true)
    )
  )
)

;; Initiates the unstaking process by setting a cooldown period
(define-public (initiate-unstake (amount uint))
  (let (
      (staking-position (unwrap! (map-get? StakingPositions tx-sender) ERR-NO-STAKE))
      (current-amount (get amount staking-position))
    )
    (asserts! (>= current-amount amount) ERR-INSUFFICIENT-STX)
    (asserts! (is-none (get cooldown-start staking-position)) ERR-COOLDOWN-ACTIVE)
    ;; Update staking position with cooldown
    (map-set StakingPositions tx-sender
      (merge staking-position { cooldown-start: (some stacks-block-height) })
    )
    (ok true)
  )
)

;; Completes the unstaking process after the cooldown period
(define-public (complete-unstake)
  (let (
      (staking-position (unwrap! (map-get? StakingPositions tx-sender) ERR-NO-STAKE))
      (cooldown-start (unwrap! (get cooldown-start staking-position) ERR-NOT-AUTHORIZED))
    )
    (asserts!
      (>= (- stacks-block-height cooldown-start) (var-get cooldown-period))
      ERR-COOLDOWN-ACTIVE
    )
    ;; Transfer STX back to user
    (try! (as-contract (stx-transfer? (get amount staking-position) tx-sender tx-sender)))
    ;; Clear staking position
    (map-delete StakingPositions tx-sender)
    (ok true)
  )
)

;; PUBLIC FUNCTIONS - GOVERNANCE

;; Allows users to create a governance proposal
(define-public (create-proposal
    (description (string-utf8 256))
    (voting-period uint)
  )
  (let (
      (user-position (unwrap! (map-get? UserPositions tx-sender) ERR-NOT-AUTHORIZED))
      (proposal-id (+ (var-get proposal-count) u1))
    )
    (asserts! (>= (get voting-power user-position) u1000000) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-description description) ERR-INVALID-PROTOCOL)
    (asserts! (is-valid-voting-period voting-period) ERR-INVALID-PROTOCOL)
    (map-set Proposals { proposal-id: proposal-id } {
      creator: tx-sender,
      description: description,
      start-block: stacks-block-height,
      end-block: (+ stacks-block-height voting-period),
      executed: false,
      votes-for: u0,
      votes-against: u0,
      minimum-votes: u1000000,
    })
    (var-set proposal-count proposal-id)
    (ok proposal-id)
  )
)

;; Allows users to vote on a governance proposal
(define-public (vote-on-proposal
    (proposal-id uint)
    (vote-for bool)
  )
  (let (
      (proposal (unwrap! (map-get? Proposals { proposal-id: proposal-id })
        ERR-INVALID-PROTOCOL
      ))
      (user-position (unwrap! (map-get? UserPositions tx-sender) ERR-NOT-AUTHORIZED))
      (voting-power (get voting-power user-position))
      (max-proposal-id (var-get proposal-count))
    )
    (asserts! (< stacks-block-height (get end-block proposal)) ERR-NOT-AUTHORIZED)
    (asserts! (and (> proposal-id u0) (<= proposal-id max-proposal-id))
      ERR-INVALID-PROTOCOL
    )
    (map-set Proposals { proposal-id: proposal-id }
      (merge proposal {
        votes-for: (if vote-for
          (+ (get votes-for proposal) voting-power)
          (get votes-for proposal)
        ),
        votes-against: (if vote-for
          (get votes-against proposal)
          (+ (get votes-against proposal) voting-power)
        ),
      })
    )
    (ok true)
  )
)

;; READ ONLY FUNCTIONS

;; Returns the contract owner
(define-read-only (get-contract-owner)
  (ok CONTRACT-OWNER)
)

;; Returns the current STX pool balance
(define-read-only (get-stx-pool)
  (ok (var-get stx-pool))
)

;; Returns the current proposal count
(define-read-only (get-proposal-count)
  (ok (var-get proposal-count))
)

;; PRIVATE FUNCTIONS

;; Retrieves tier information based on the stake amount
(define-private (get-tier-info (stake-amount uint))
  (if (>= stake-amount u10000000)
    {
      tier-level: u3,
      reward-multiplier: u200,
    }
    (if (>= stake-amount u5000000)
      {
        tier-level: u2,
        reward-multiplier: u150,
      }
      {
        tier-level: u1,
        reward-multiplier: u100,
      }
    )
  )
)

;; Calculates the lock multiplier based on the lock period
(define-private (calculate-lock-multiplier (lock-period uint))
  (if (>= lock-period u8640) ;; 2 months
    u150 ;; 1.5x multiplier
    (if (>= lock-period u4320) ;; 1 month
      u125 ;; 1.25x multiplier
      u100 ;; 1x multiplier (no lock)
    )
  )
)

;; Calculates the rewards for a user based on their stake and the number of blocks
(define-private (calculate-rewards
    (user principal)
    (blocks uint)
  )
  (let (
      (staking-position (unwrap! (map-get? StakingPositions user) u0))
      (user-position (unwrap! (map-get? UserPositions user) u0))
      (stake-amount (get amount staking-position))
      (base-rate (var-get base-reward-rate))
      (multiplier (get rewards-multiplier user-position))
    )
    (/ (* (* (* stake-amount base-rate) multiplier) blocks) u14400000)
  )
)

;; Validates the proposal description length
(define-private (is-valid-description (desc (string-utf8 256)))
  (and
    (>= (len desc) u10) ;; Minimum description length
    (<= (len desc) u256) ;; Maximum description length
  )
)

;; Validates the lock period
(define-private (is-valid-lock-period (lock-period uint))
  (or
    (is-eq lock-period u0) ;; No lock
    (is-eq lock-period u4320) ;; 1 month
    (is-eq lock-period u8640) ;; 2 months
  )
)

;; Validates the voting period
(define-private (is-valid-voting-period (period uint))
  (and
    (>= period u100) ;; Minimum voting blocks
    (<= period u2880) ;; Maximum voting blocks (approximately 1 day)
  )
)
