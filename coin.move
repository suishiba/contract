module admin::suishiba {
    use std::vector;
    use std::option;
    use std::string::{Self, utf8, String};

    use sui::object::{Self, ID, UID};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin, TreasuryCap, value, split, destroy_zero};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::pay;
    use sui::dynamic_object_field as dof;
    use sui::url::{Self, Url};

    use admin::math;
    use owner::airsuishiba::{AIRSUISHIBA};

    const LIQUIDITY_ADDRESS: address = @liquidity;
    const AIRDROP_ADDRESS: address = @airdrop;
    const TEAM_ADDRESS: address = @team;
    const MARKETING_ADDRESS: address = @marketing;
    const TOKEN_SALE_ADDRESS: address = @sale;

    // TGE ms timestamp
    const TGE_TIME: u64 = 1683275160000;

    // 1 month = 2629800000 ms
    const PERIOD_DURATION: u64 = 2629800000;

    // The TOKEN SALE supply of SuiShiba Token (10 Billion * 10^6)
    const TOKEN_SALE_SUPPLY: u64 = 10_000_000_000_000_000;

    // The TEAM supply of SuiShiba Token (15 Billion * 10^6)
    const TEAM_SUPPLY: u64 = 15_000_000_000_000_000;

    // The LIQUIDITY supply of SuiShiba Token (30 Billion * 10^6)
    const LIQUIDITY_SUPPLY: u64 = 30_000_000_000_000_000;

    // The MARKETING supply of SuiShiba Token (15 Billion * 10^6)
    const MARKETING_SUPPLY: u64 = 15_000_000_000_000_000;

    // The AIRDROP supply of SuiShiba Token (30 Billion * 10^6)
    const AIRDROP_SUPPLY: u64 = 30_000_000_000_000_000;

    // Error messages
    const EVESTING_STARTS_TOO_SOON: u64 = 0;
    const EVESTING_IS_NOT_DUE: u64 = 1;
    const EVESTING_AMOUNT_IS_ZERO: u64 = 2;
    const EINVALID_LOCK_TIME: u64 = 3;
    const ELOCK_AMOUNT_IS_ZERO: u64 = 4;
    const EINSUFFICIENT_AMOUNT: u64 = 5;
    const ELOCKUP_IS_CLAIMED: u64 = 6;
    const ELOCKUP_HAS_NOT_EXPIRED: u64 = 7;
    const EVESTING_IS_DONE: u64 = 8;

    /// Name of the coin. By convention, this type has the same name as its parent module
    /// and has no fields. The full type of the coin defined by this module will be `COIN<SUISHIBA>`.
    struct SUISHIBA has drop {}

    struct OwnerCap has key {
        id: UID,
        owner: address
    }

    struct VestingMap has store {
        total_amount: u64, // Sum of all released amount   
        released_amount: u64, // Sum of already released amount
        vesting_start: u64,
        last_completed_period: u64,
        tge_status: bool,
        tge_percent: u64,
        cycle_amount: u64
    }

    struct Distribution has key, store {
        id: UID,
        name: String,
        account: address,
        vesting: VestingMap
    }

    struct Global has key, store {
        id: UID,
        treasury_cap: TreasuryCap<SUISHIBA>,
        team_distribution: Distribution,
        airdrop_distribution: Balance<SUISHIBA>
    }

    struct Lock has key, store {
        id: UID,
        name: String,
        owner: address,
        amount: u64,
        balance: Balance<SUISHIBA>,
        unlock_time_ms: u64,
        is_claimed: bool
    }

    struct LockInfo has key, store {
        id: UID,
        name: String,
        owner: address,
        amount: u64,
        unlock_time_ms: u64,
        is_claimed: bool
    }

    /// Register the SUISHIBA currency to acquire its `TreasuryCap`. Because
    /// this is a module initializer, it ensures the currency only gets
    /// registered once.
    fun init(witness: SUISHIBA, ctx: &mut TxContext) {
        let owner = tx_context::sender(ctx);
        let icon_url = url::new_unsafe_from_bytes(b"https://pbs.twimg.com/profile_images/1652612936764997633/fHY1LNIz_400x400.jpg");
        let icon_url_option = option::none<Url>();
        option::fill<Url>(&mut icon_url_option, icon_url);
        
        // Get a treasury cap for the coin and give it to the transaction sender
        let (treasury_cap, metadata) = coin::create_currency<SUISHIBA>(
            witness,
            6, 
            b"SuiShib", 
            b"SuiShiba", 
            b"#SuiShiba is a community-driven meme project. Built by a team of believers, Suishiba is ready to take on any challenge and have some fun along the way!",
            icon_url_option,
            ctx
        );
        // Mint TOKEN SALE supply to TOKEN_SALE_ADDRESS
        coin::mint_and_transfer(&mut treasury_cap, TOKEN_SALE_SUPPLY, TOKEN_SALE_ADDRESS, ctx);

        // Mint LIQUIDITY supply to LIQUIDITY_ADDRESS
        coin::mint_and_transfer(&mut treasury_cap, LIQUIDITY_SUPPLY, LIQUIDITY_ADDRESS, ctx);

        // Mint MARKETING supply to MARKETING_ADDRESS
        coin::mint_and_transfer(&mut treasury_cap, MARKETING_SUPPLY, MARKETING_ADDRESS, ctx);

        // Transfer OwnerCap to owner
        transfer::transfer(
            OwnerCap {
                id: object::new(ctx),
                owner,
            }, 
            owner
        );

        // Team Supply
        let team_vesting_map = VestingMap {
            total_amount: TEAM_SUPPLY,  
            released_amount: 0,
            vesting_start: PERIOD_DURATION * 5 + TGE_TIME,
            last_completed_period: PERIOD_DURATION * 5 + TGE_TIME,
            tge_status: true,
            tge_percent: 0,
            cycle_amount: math::mul_div(TEAM_SUPPLY, 10, 100),
        };
        let team_distribution = Distribution {
            id: object::new(ctx),
            name: utf8(b"Team"),
            account: TEAM_ADDRESS,
            vesting: team_vesting_map
        };

        // After minting Public Sale supply, wrap the TreasuryCap into Global
        let global = Global {
            id: object::new(ctx),
            treasury_cap,
            team_distribution,
            airdrop_distribution: balance::zero<SUISHIBA>(),
        };

        // Mint AIRDROP supply
        let airdrop_coin = coin::mint(&mut global.treasury_cap, AIRDROP_SUPPLY, ctx);
        let airdrop_balance = coin::into_balance(airdrop_coin);
        balance::join(&mut global.airdrop_distribution, airdrop_balance);

        transfer::public_share_object(global);
        transfer::public_share_object(metadata)
    }

    /// User can burn coins
    public entry fun burn(
        global: &mut Global,
        coin: Coin<SUISHIBA>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(value(&coin) >= amount, EINSUFFICIENT_AMOUNT);

        // 1. burn coin
        let coin_in = split(&mut coin, amount, ctx);
        coin::burn(&mut global.treasury_cap, coin_in);

        // 2. handle remain coin
        if (value(&coin) > 0) {
            transfer::public_transfer(
                coin,
                tx_context::sender(ctx)
            )
        } else {
            destroy_zero(coin)
        }
    }

    public entry fun multi_burn(
        global: &mut Global,
        coins: vector<Coin<SUISHIBA>>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        // 1. merge coins
        let merged_coins_in = vector::pop_back(&mut coins);
        pay::join_vec(&mut merged_coins_in, coins);
        let coin_in = split(&mut merged_coins_in, amount, ctx);

        // 2. burn coin
        coin::burn(&mut global.treasury_cap, coin_in);

        // 3. handle remain coin
        if (value(&merged_coins_in) > 0) {
            transfer::public_transfer(
                merged_coins_in,
                tx_context::sender(ctx)
            )
        } else {
            destroy_zero(merged_coins_in)
        }
    }

    /// Owner can transfer the ownership
    public entry fun transfer_ownership(
        owner_cap: OwnerCap,
        receiver: address,
        _ctx: &mut TxContext
    ) {
        owner_cap.owner = receiver;

        transfer::transfer(
            owner_cap,
            receiver
        )
    }

    /// Owner can renounce the ownership
    public entry fun renounce_ownership(
        owner_cap: OwnerCap,
        _ctx: &mut TxContext
    ) {
        let OwnerCap { id, owner: _ } = owner_cap;
        object::delete(id)
    }

    // Vesting Management
    fun calculate_total_vesting_time(
        last_completed_period: u64,
        time_now: u64
    ): u64 {
        let last_completed = last_completed_period;
        
        let time_pass: u64 = if (time_now > last_completed) {
           (time_now - last_completed) / PERIOD_DURATION
        } else {
            0
        };

        time_pass
    }

    fun calculate_vesting_amount(
        distribution: &mut Distribution,
        time_now: u64
    ): u64 {
        assert!(distribution.vesting.released_amount < distribution.vesting.total_amount, EVESTING_IS_DONE);
        let _amount_to_be_released = 0;

        // Distribute vesting
        let tge_percent = distribution.vesting.tge_percent; // %
        let vesting_start = distribution.vesting.vesting_start;
        // Short-circuit if vesting hasn't started yet.
        assert!(time_now > vesting_start, EVESTING_STARTS_TOO_SOON);

        // Check TGE
        if (tge_percent > 0 && distribution.vesting.tge_status) {
            _amount_to_be_released = math::mul_div(distribution.vesting.total_amount, tge_percent, 100);
            distribution.vesting.released_amount = distribution.vesting.released_amount + _amount_to_be_released;
            distribution.vesting.tge_status = false;
        } else {
            // Check if the next vesting period has already passed. If not, short-circuit since there's nothing to vest.
            let vesting_time = calculate_total_vesting_time(
                distribution.vesting.last_completed_period,
                time_now
            );
            assert!(vesting_time > 0, EVESTING_IS_NOT_DUE);
            
            let vest_time_ms = vesting_time * PERIOD_DURATION;
            let vest_completed_period = distribution.vesting.last_completed_period + vest_time_ms;
            assert!(time_now > vest_completed_period, EVESTING_STARTS_TOO_SOON);

            let coin_to_claim = distribution.vesting.cycle_amount * vesting_time;
            let coin_can_claim = distribution.vesting.total_amount - distribution.vesting.released_amount;

            _amount_to_be_released = if (coin_to_claim >= coin_can_claim) {
                coin_can_claim
            } else {
                coin_to_claim
            };

            distribution.vesting.released_amount = distribution.vesting.released_amount + _amount_to_be_released;
            distribution.vesting.last_completed_period = vest_completed_period;
        };

        _amount_to_be_released
    }

    /// Team Distribution Vesting
    public entry fun team_vesting(
        _owner_cap: &OwnerCap,
        global: &mut Global,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let time_now = clock::timestamp_ms(clock);

        let amount_to_be_released: u64 = calculate_vesting_amount(&mut global.team_distribution, time_now);
        assert!(amount_to_be_released > 0, EVESTING_AMOUNT_IS_ZERO);

        let owner_addr = global.team_distribution.account;
        coin::mint_and_transfer(&mut global.treasury_cap, amount_to_be_released, owner_addr, ctx);
    }
    
    public entry fun lock(
        global: &mut Global,
        clock: &Clock,
        name: vector<u8>,
        unlock_time_ms: u64,
        coin: Coin<SUISHIBA>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let time_now = clock::timestamp_ms(clock);
        assert!(unlock_time_ms > time_now, EINVALID_LOCK_TIME);
        assert!(amount > 0, ELOCK_AMOUNT_IS_ZERO);
        assert!(value(&coin) >= amount, EINSUFFICIENT_AMOUNT);

        let owner_addr = tx_context::sender(ctx);
        let lock_id = object::new(ctx);
        let id_copy = object::uid_to_inner(&lock_id);
        let string_name = string::utf8(name);

        let lock = Lock {
            id: lock_id,
            name: string_name,
            owner: owner_addr,
            amount,
            balance: balance::zero<SUISHIBA>(),
            unlock_time_ms,
            is_claimed: false,
        };

        // Add Lock Coin
        let locked_coin = coin::split(&mut coin, amount, ctx);
        let locked_balance = coin::into_balance(locked_coin);
        
        // Update Lock Information
        balance::join(&mut lock.balance, locked_balance);

        transfer::transfer(lock, owner_addr);

        dof::add(
            &mut global.id,
            id_copy,
            LockInfo {
                id: object::new(ctx),
                name: string_name,
                owner: owner_addr,
                amount,
                unlock_time_ms,
                is_claimed: false,
            }
        );

        // Handle remain coin
        if (value(&coin) > 0) {
            transfer::public_transfer(
                coin,
                owner_addr
            )
        } else {
            destroy_zero(coin)
        }
    }

    public entry fun unlock(
        global: &mut Global,
        lock: &mut Lock,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!lock.is_claimed, ELOCKUP_IS_CLAIMED);
        let time_now = clock::timestamp_ms(clock);
        assert!(time_now >= lock.unlock_time_ms, ELOCKUP_HAS_NOT_EXPIRED);

        let locked_balance = balance::value<SUISHIBA>(&lock.balance);
        let claim_coin = coin::take<SUISHIBA>(&mut lock.balance, locked_balance, ctx);
        transfer::public_transfer(claim_coin, lock.owner);

        lock.is_claimed = true;

        // Update Global LockInfo
        let id_copy = object::uid_to_inner(&lock.id);
        let lock_info = dof::borrow_mut<ID, LockInfo>(&mut global.id, id_copy);
        lock_info.is_claimed = true;
    }

    /// Conversion
    public entry fun convert(
        global: &mut Global,
        air_coin: Coin<AIRSUISHIBA>,
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);
        let amount = value(&air_coin);

        let air_coin_claimed = coin::take<SUISHIBA>(&mut global.airdrop_distribution, amount, ctx);
        transfer::public_transfer(air_coin_claimed, sender_addr);
        transfer::public_freeze_object(air_coin);
    }
}