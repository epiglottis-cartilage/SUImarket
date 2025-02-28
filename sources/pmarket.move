module pmarket::pmarket{
    use sui::coin::{Self, Coin};
    use sui::dynamic_object_field as dof;
    use sui::event;
    use sui::package;
    use sui::sui::SUI;
    use sui::object_table::{Self, ObjectTable};
    use sui::vec_set::{Self, VecSet};

    // ===   OTW  ===
    public struct PMARKET has drop{}

    // === Errors ===
    #[error]
    const EInvalidAmount: vector<u8> = b"AmountNotMatch";
    #[error]
    const EInvalidNft: vector<u8> = b"NftNotFound";
    #[error]
    const EInvalidListing: vector<u8> = b"ListingNotFound";
    #[error]
    const EInvalidOwner: vector<u8> = b"InvalidOwner";

    // === Events ===
    /// Event emitted when a marketplace is initialized.
    public struct MarketplaceInit has copy, drop {
        object_id: ID,
    }
    /// Event emitted when a listing is created.
    public struct ListingCreated has copy, drop {
        listing_id: ID,
        nft_id: ID,
        owner: address,
        price: u64,
    }
    /// Event emitted when a listing is cancelled.
    public struct ListingCancelled has copy, drop {
        listing_id: ID,
        nft_id: ID,
        owner: address,
        price: u64,
    }
    /// Event emitted when a listing is bought.
    public struct Buy has copy, drop {
        listing_id: ID,
        nft_id: ID,
        owner: address,
        buyer: address,
        price: u64,
    }

    // === Structs ===
    /// To sell a NFT, the owner will create a listing.
    /// The NFT is bind to the listing, using dynamic object field,
    /// and the key is the nft_id.
    public struct Listing has key, store {
        id: UID,
        price: u64,
        owner: address,
        nft_id: ID
    }

    /// Marketplace contains all the listings.
    public struct Marketplace has key {
        id: UID,
        listings: ObjectTable<ID, Listing>,
        listing_ids: VecSet<ID>,
    }

    // Part 3: Module initializer to be executed when this module is published
    fun init(otw: PMARKET, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);
        transfer::public_transfer(publisher, ctx.sender());

        let marketplace = Marketplace {
            id: object::new(ctx),
            listings: object_table::new<ID, Listing>(ctx),
            listing_ids: vec_set::empty(),
        };

        event::emit(MarketplaceInit {
            object_id: object::id(&marketplace),
        });

        transfer::share_object(marketplace);
    }

    public fun sell<N: key + store>(
        marketplace: &mut Marketplace, 
        nft: N, 
        price: u64, 
        ctx: &mut TxContext
    ): ID {
        let sender = ctx.sender();
        let nft_id = object::id(&nft);
        let mut listing = Listing {
            id: object::new(ctx),
            price,
            owner: sender,
            nft_id
        };
        let listing_id = listing.id.to_inner();
        dof::add(&mut listing.id, nft_id, nft);

        marketplace.listings.add(nft_id, listing);
        marketplace.listing_ids.insert(listing_id);

        event::emit(ListingCreated {
            listing_id,
            nft_id,
            owner: sender,
            price,
        });

        listing_id
    }

    public fun cancel<N: key + store>(
        marketplace: &mut Marketplace,
        nft_id: ID,
        ctx: &mut TxContext
    ): N {
        let sender = ctx.sender();
        assert!(marketplace.listings.contains<ID, Listing>(nft_id), EInvalidListing);

        let mut listing = marketplace.listings.remove<ID, Listing>(nft_id);
        assert!(listing.owner == sender, EInvalidOwner);

        let nft: N = dof::remove(&mut listing.id, nft_id);
        let Listing { id, owner, price, nft_id: _ } = listing;

        let listing_id = id.to_inner();
        marketplace.listing_ids.remove(&listing_id);
        id.delete();

        event::emit(ListingCancelled {
            listing_id,
            nft_id,
            owner,
            price,
        });

        nft
    }

    public fun buy<N: key + store>(
        marketplace: &mut Marketplace,
        nft_id: ID,
        mut coin: Coin<SUI>,
        ctx: &mut TxContext
    ): N {
        assert!(object_table::contains(&marketplace.listings, nft_id), EInvalidNft);

        let mut listing = marketplace.listings.remove<ID, Listing>(nft_id);

        let nft: N = dof::remove(&mut listing.id, nft_id);
        let Listing { id, owner, price, nft_id: _ } = listing;

        let listing_id = id.to_inner();
        marketplace.listing_ids.remove(&listing_id);
        id.delete();

        if(coin.value() > price){
            let extra = coin.value() - price;
            coin.split_and_transfer(extra, ctx.sender(), ctx);
        };
        assert!(coin.value() == price, EInvalidAmount);
        transfer::public_transfer(coin, owner);

        event::emit(Buy {
            listing_id,
            nft_id: object::id(&nft),
            owner: owner,
            buyer: ctx.sender(),
            price,
        });

        nft
    }
    
    #[test]
    fun test_module_init() {
        use sui::test_scenario;
        use sui::package::Publisher;
        use std::ascii;

        let admin = @0xAD;

        let mut scenario = test_scenario::begin(admin);
        {
            init(PMARKET {}, scenario.ctx());
        };

        scenario.next_tx(admin);
        {
            let marketplace_id = test_scenario::most_recent_id_shared<Marketplace>().destroy_some();
            let marketplace: Marketplace = scenario.take_shared_by_id(marketplace_id);
            assert!(marketplace.listings.is_empty());
            
            test_scenario::return_shared(marketplace);

            let publisher = scenario.take_from_sender<Publisher>();
            assert!(publisher.published_module() == ascii::string(b"pmarket"), 1);
            scenario.return_to_sender(publisher);
        };
        scenario.end();
    }

    #[test]
    fun test_place_listing() {
        use sui::test_scenario;
        use sui::test_utils::assert_eq;
        use pmarket::test_nft::{TestnetNFT, mint};
        use std::string;
        use sui::url;

        let admin = @0xAD;
        let owner = @0xB0;

        let nft_id;

        let mut scenario = test_scenario::begin(admin);
        {
            init(PMARKET {}, scenario.ctx());
        };

        scenario.next_tx(owner);
        {
            let nft = mint(b"Name", b"Description", b"https://url", scenario.ctx());
            nft_id = object::id(&nft);
            transfer::public_transfer(nft, owner);
        };

        scenario.next_tx(owner);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let nft = scenario.take_from_sender<TestnetNFT>();
            let listing_id = sell(&mut marketplace, nft, 10, scenario.ctx());

            assert_eq(marketplace.listings.length(), 1);

            assert_eq(object::id(marketplace.listings.borrow(nft_id)),listing_id);

            test_scenario::return_shared(marketplace);
        };

        let effects = scenario.next_tx(owner);
        assert_eq(effects.num_user_events(), 1);

        {
            let marketplace = scenario.take_shared<Marketplace>();
            let listing = marketplace.listings.borrow<ID, Listing>(nft_id);

            assert_eq(listing.owner, owner);
            assert_eq(listing.price, 10);

            let nft: &TestnetNFT = dof::borrow<ID, TestnetNFT>(&listing.id, nft_id);

            assert!(nft.name() == string::utf8(b"Name"), 1);
            assert!(nft.description() == string::utf8(b"Description"), 1);
            assert!(nft.url() == url::new_unsafe_from_bytes(b"https://url"), 1);
            assert!(nft.creator() == owner, 1);
            test_scenario::return_shared(marketplace);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidListing)]
    fun test_cancel_listing_error_not_found() {
        use sui::test_scenario;
        use pmarket::test_nft::TestnetNFT;

        let admin = @0xAD;
        let seller = @0xFAFE;
        let nft_id = object::id_from_address(@0x3333);

        let mut scenario = test_scenario::begin(admin);
        {
            init(PMARKET {}, scenario.ctx());
        };

        scenario.next_tx(seller);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            // Listing not exist, Should panic
            let nft: TestnetNFT = cancel(&mut marketplace, nft_id, scenario.ctx());

            test_scenario::return_shared(marketplace);
            transfer::public_transfer(nft, seller);
        };

        scenario.end();
    }

    #[test]
    fun test_cancel_listing() {
        use sui::test_scenario;
        use sui::test_utils::assert_eq;
        use pmarket::test_nft::{TestnetNFT, mint};

        let admin = @0xAD;
        let seller = @0xCAFE;
        let nft_id;


        let mut scenario = test_scenario::begin(admin);
        {
            init(PMARKET {}, scenario.ctx());
        };

        scenario.next_tx(seller);
        {
            let nft = mint(b"Name", b"Description", b"https://url", scenario.ctx());
            nft_id = object::id(&nft);
            transfer::public_transfer(nft, seller);
        };

        scenario.next_tx(seller);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let nft = scenario.take_from_sender<TestnetNFT>();

            sell(&mut marketplace, nft, 3, scenario.ctx());

            test_scenario::return_shared(marketplace);
        };

        // Cancel listing
        scenario.next_tx(seller);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();

            let nft: TestnetNFT = cancel(&mut marketplace, nft_id, scenario.ctx());

            assert_eq(marketplace.listings.length(), 0);

            test_scenario::return_shared(marketplace);
            transfer::public_transfer(nft, seller);
        };

        let effects = scenario.next_tx(seller);
        assert_eq(effects.num_user_events(), 1); // 1 event emitted

        scenario.end();
    }

    #[test]
    fun test_buy() {
        use sui::test_scenario;
        use sui::test_utils::assert_eq;
        use pmarket::test_nft::{TestnetNFT, mint};

        let admin = @0xAD;
        let seller = @0xCAFE;
        let buyer = @0xFAFE;
        let nft_id;

        let mut scenario = test_scenario::begin(admin);
        {
            init(PMARKET {}, scenario.ctx());
        };

        scenario.next_tx(seller);
        {
            let nft = mint(b"Name", b"Description", b"url", scenario.ctx());
            nft_id = object::id(&nft);
            transfer::public_transfer(nft, seller);

            let coin = coin::mint_for_testing<SUI>(10, scenario.ctx());
            transfer::public_transfer(coin, buyer);
        };

        // Place listing
        scenario.next_tx(seller);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let nft = scenario.take_from_sender<TestnetNFT>();

            sell(&mut marketplace, nft, 10, scenario.ctx());

            assert_eq(marketplace.listings.length(), 1);

            test_scenario::return_shared(marketplace);
        };

        // Do buy
        scenario.next_tx(buyer);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let coin = scenario.take_from_sender<Coin<SUI>>();
            let nft: TestnetNFT = buy(&mut marketplace, nft_id, coin, scenario.ctx());

            assert_eq(marketplace.listings.length(), 0);

            test_scenario::return_shared(marketplace);
            transfer::public_transfer(nft, buyer);
        };

        let effects = scenario.next_tx(seller);
        assert_eq(effects.num_user_events(), 1); // 1 event emitted

        // Seller got initial coin
        {
            let coin = scenario.take_from_sender<Coin<SUI>>();
            assert_eq(coin.value(), 10);
            scenario.return_to_sender(coin);
        };

        scenario.end();
    }


    #[test]
    fun test_buy_extra_coin() {
        use sui::test_scenario;
        use sui::test_utils::assert_eq;
        use pmarket::test_nft::{TestnetNFT, mint};

        let admin = @0xAD;
        let seller = @0xCAFE;
        let buyer = @0xFAFE;
        let nft_id;

        let mut scenario = test_scenario::begin(admin);
        {
            init(PMARKET {}, scenario.ctx());
        };

        scenario.next_tx(seller);
        {
            let nft = mint(b"Name", b"Description", b"url", scenario.ctx());
            nft_id = object::id(&nft);
            transfer::public_transfer(nft, seller);

            let coin = coin::mint_for_testing<SUI>(15, scenario.ctx());
            transfer::public_transfer(coin, buyer);
        };

        // Place listing
        scenario.next_tx(seller);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let nft = scenario.take_from_sender<TestnetNFT>();

            sell(&mut marketplace, nft, 10, scenario.ctx());

            assert_eq(marketplace.listings.length(), 1);

            test_scenario::return_shared(marketplace);
        };

        // Do buy
        scenario.next_tx(buyer);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let coin = scenario.take_from_sender<Coin<SUI>>();
            let nft: TestnetNFT = buy(&mut marketplace, nft_id, coin, scenario.ctx());

            assert_eq(marketplace.listings.length(), 0);

            test_scenario::return_shared(marketplace);
            transfer::public_transfer(nft, buyer);
        };

        let effects = scenario.next_tx(seller);
        assert_eq(effects.num_user_events(), 1); // 1 event emitted

        // Seller got coin
        {
            let coin = scenario.take_from_sender<Coin<SUI>>();
            assert_eq(coin.value(), 10);
            scenario.return_to_sender(coin);
        };

        // Buyer got extra coin return
        scenario.next_tx(buyer);
        {

            let coin = scenario.take_from_sender<Coin<SUI>>();
            assert_eq(coin.value(), 5);
            scenario.return_to_sender(coin);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidAmount)]
    fun test_buy_error_amount() {
        use sui::test_scenario;
        use sui::test_utils::assert_eq;
        use pmarket::test_nft::{TestnetNFT, mint};

        
        let admin = @0xAD;
        let seller = @0xCAFE;
        let buyer = @0xFAFE;

        let nft_id;

        let mut scenario = test_scenario::begin(admin);
        {
            init(PMARKET {}, scenario.ctx());
        };

        scenario.next_tx(seller);
        {
            let nft = mint(b"Name", b"Description", b"url", scenario.ctx());
            nft_id = object::id(&nft);
            transfer::public_transfer(nft, seller);

            let coin = coin::mint_for_testing<SUI>(20, scenario.ctx());
            transfer::public_transfer(coin, buyer);
        };

        // Create listing
        scenario.next_tx(seller);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let nft = scenario.take_from_sender<TestnetNFT>();

            sell(&mut marketplace, nft, 50, scenario.ctx());

            assert_eq(marketplace.listings.length(), 1);

            test_scenario::return_shared(marketplace);
        };

        // Buy with error
        scenario.next_tx(buyer);
        {
            let mut marketplace = scenario.take_shared<Marketplace>();
            let coin = scenario.take_from_sender<Coin<SUI>>();

            let nft: TestnetNFT = buy(&mut marketplace, nft_id, coin, scenario.ctx());

            test_scenario::return_shared(marketplace);
            transfer::public_transfer(nft, buyer);
        };

        scenario.end();
    }
}
