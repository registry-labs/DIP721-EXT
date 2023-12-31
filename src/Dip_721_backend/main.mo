import JSON "mo:json/JSON";
import HashMap "mo:stable/HashMap";
import StableBuffer "mo:stable-buffer/StableBuffer";
import Debug "mo:base/Debug";
import Buffer "mo:base/Buffer";
import List "mo:base/List";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Float "mo:base/Float";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Error "mo:base/Error";
import TrieMap "mo:base/TrieMap";
import Trie "mo:base/Trie";
import Metadata "models/Metadata";
import Offer "models/Offer";
import Price "models/Price";
import Bid "models/Bid";
import Principal "mo:base/Principal";
import Prim "mo:prim";
import Cycles "mo:base/ExperimentalCycles";
import Nat32 "mo:base/Nat32";
import Nat8 "mo:base/Nat8";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Dip20 "./services/Dip20";
import Dip20_EXT "./services/Dip20_EXT";
import ICRC2 "./services/ICRC2";
import Nat64 "mo:base/Nat64";
import Utils "common/Utils";
import Token "./models/Token";
import Auction "./models/Auction";
import CollectionRequest "./models/CollectionRequest";
import Http "./common/http";
import Attribute "./models/Attribute";
import WhiteList "./models/WhiteList";
import Constants "../Constants";
import { recurringTimer; cancelTimer; setTimer } = "mo:base/Timer";
import Random "mo:base/Random";
import Option "mo:base/Option";
import Int "mo:base/Int";
import Transaction "./models/Transaction";
import Order "mo:base/Order";

actor class Dip721(collectionRequest : CollectionRequest.CollectionRequest) = this {

  private type Metadata = Metadata.Metadata;
  private type Offer = Offer.Offer;
  private type Price = Price.Price;
  private type Bid = Bid.Bid;
  private type OfferRequest = Offer.OfferRequest;
  private type Token = Token.Token;
  private type Auction = Auction.Auction;
  private type AuctionRequest = Auction.AuctionRequest;
  private type JSON = JSON.JSON;
  private type WhiteList = WhiteList.WhiteList;
  private type Transaction = Transaction.Transaction;

  let pHash = Principal.hash;
  let pEqual = Principal.equal;

  let tHash = Text.hash;
  let tEqual = Text.equal;

  let n32Hash = func(a : Nat32) : Nat32 { a };
  let n32Equal = Nat32.equal;

  let icrc2Buffer = 1000000000 * 1;

  private stable var collectionOwner = Principal.fromText(collectionRequest.collectionCreator);
  private stable var collectionCreator = Principal.fromText(collectionRequest.collectionCreator);
  private stable let royalty = collectionRequest.royalty;
  private stable let name = collectionRequest.name;
  private stable let external_url = collectionRequest.external_url;
  private stable let description = collectionRequest.description;
  private stable let banner = collectionRequest.bannerImage;
  private stable let profile = collectionRequest.profileImage;
  private stable var isMinting = false;
  private stable var isWhiteListMinting = false;

  private var capacity = 1000000000000000000;
  private var cyclesBalance = Cycles.balance();

  private stable var mintId : Nat32 = 1;
  private stable var transactionId : Nat32 = 1;
  private stable var offerId : Nat32 = 1;
  private stable var imageId : Nat32 = 1;
  private stable var holders = HashMap.empty<Principal, HashMap.HashMap<Nat32, Metadata>>();
  private stable var claims = HashMap.empty<Principal, Nat>();
  private stable var manifest = HashMap.empty<Nat32, Principal>();
  private stable var metaData = HashMap.empty<Nat32, Metadata>();
  private stable var offers = HashMap.empty<Nat32, [Offer]>();
  private stable var sales = HashMap.empty<Nat32, OfferRequest>();
  private stable var ledger = HashMap.empty<Nat32, Transaction>();
  private stable var approved = HashMap.empty<Nat32, Principal>();
  private stable var auctions = HashMap.empty<Nat32, Auction>();
  private stable var bids = HashMap.empty<Nat32, HashMap.HashMap<Principal, Offer>>();
  private stable var winningBids = HashMap.empty<Nat32, Offer>();
  private stable var priceHistory = HashMap.empty<Nat32, StableBuffer.StableBuffer<Price>>();
  private stable var whiteList : [WhiteList] = [];
  private stable var currentWhiteList : ?WhiteList = null;
  private stable var images = HashMap.empty<Nat32, Blob>();

  ///Query Methods
  public query func getMemorySize() : async Nat {
    let size = Prim.rts_memory_size();
    size;
  };

  public query func getHeapSize() : async Nat {
    let size = Prim.rts_heap_size();
    size;
  };

  public query func getCycles() : async Nat {
    Cycles.balance();
  };

  public query func getName() : async Text {
    name;
  };

  public query func getDescription() : async Text {
    description;
  };

  public query func getRoyalty() : async Float {
    royalty;
  };

  public query func getCollectionOwner() : async Principal {
    collectionOwner;
  };

  public query func getCollectionCreator() : async Principal {
    collectionCreator;
  };

  public query func getOwner(_mintId : Nat32) : async Principal {
    _getOwner(_mintId);
  };

  public query func fetchWhiteList() : async [WhiteList] {
    whiteList;
  };

  public query func getCurrentWhiteList() : async WhiteList {
    switch (currentWhiteList) {
      case (?currentWhiteList) {
        currentWhiteList;
      };
      case (null) {
        throw (Error.reject("Not Found"));
      };
    };
  };

  public query func fetchTransactions(start : Nat, limit : Nat) : async [(Nat32, Transaction)] {
    let temp = Iter.toArray(HashMap.entries(ledger));
    func order(a : (Nat32, Transaction), b : (Nat32, Transaction)) : Order.Order {
      return Nat32.compare(b.1.mintId, a.1.mintId);
    };
    let sorted = Array.sort(temp, order);
    let limit_ : Nat = if (start + limit > temp.size()) {
      temp.size() - start;
    } else {
      limit;
    };
    var res : [(Nat32, Transaction)] = [];
    for (i in Iter.range(0, limit_ - 1)) {
      res := Array.append(res, [sorted[i + start]]);
    };
    return res;
  };

  public query func fetchOffers(_mintId : Nat32) : async [Offer] {
    let exist = HashMap.get(offers, _mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        exist;
      };
      case (null) { [] };
    };
  };

  public query func fetchAuctions() : async [Auction] {
    var _auctions = Buffer.Buffer<Auction>(0);
    for ((id, _auction) in HashMap.entries(auctions)) {
      _auctions.add(_auction);
    };
    Buffer.toArray(_auctions);
  };

  public query func fetchBids(_mintId : Nat32) : async [Bid] {
    let exist = HashMap.get(bids, _mintId, n32Hash, n32Equal);
    var _bids = Buffer.Buffer<Bid>(0);
    switch (exist) {
      case (?exist) {
        for ((owner, _offer) in HashMap.entries(exist)) {
          _bids.add({ owner = owner; offer = _offer });
        };
      };
      case (null) {

      };
    };
    Buffer.toArray(_bids);
  };

  public query func fetchSales() : async [OfferRequest] {
    var _bids = Buffer.Buffer<OfferRequest>(0);
    for ((id, _offer) in HashMap.entries(sales)) {
      _bids.add(_offer);
    };
    Buffer.toArray(_bids);
  };

  public query func fetchOwners(_mintIds : [Nat32]) : async [{
    owner : Principal;
    mintId : Nat32;
  }] {
    var result = Buffer.Buffer<{ owner : Principal; mintId : Nat32 }>(0);
    for (_mintId in _mintIds.vals()) {
      result.add({ owner = _getOwner(_mintId); mintId = _mintId });
    };
    Buffer.toArray(result);
  };

  public query func balance(owner : Principal) : async [Metadata] {
    let exist = HashMap.get(holders, owner, pHash, pEqual);
    var result = Buffer.Buffer<Metadata>(0);
    switch (exist) {
      case (?exist) {
        for ((id, data) in HashMap.entries(exist)) {
          result.add(data);
        };
      };
      case (null) {
        throw (Error.reject("No Data for Principal " #Principal.toText(owner)));
      };
    };
    Buffer.toArray(result);
  };

  public query func balance_of(owner : Principal) : async [Nat32] {
    let exist = HashMap.get(holders, owner, pHash, pEqual);
    var result = Buffer.Buffer<Nat32>(0);
    switch (exist) {
      case (?exist) {
        for ((id, data) in HashMap.entries(exist)) {
          result.add(id);
        };
      };
      case (null) {
        throw (Error.reject("No Data for Principal " #Principal.toText(owner)));
      };
    };
    Buffer.toArray(result);
  };

  public query func fetchPriceHistory(since : ?Time.Time, _mintId : Nat32) : async [Price] {
    let _prices = _fetchPriceHistory(_mintId);
    switch (since) {
      case (?since) {
        Array.filter(_prices, func(e : Price) : Bool { e.timeStamp > since });
      };
      case (null) {
        _prices;
      };
    };
  };

  public query func getData(_mintId : Nat32) : async Metadata {
    let _owner = _getOwner(_mintId);
    let exist = HashMap.get(holders, _owner, pHash, pEqual);
    switch (exist) {
      case (?exist) {
        switch (HashMap.get(exist, _mintId, n32Hash, n32Equal)) {
          case (?data) {
            data;
          };
          case (null) {
            throw (Error.reject("No Data for mintId " #Nat32.toText(_mintId)));
          };
        };
      };
      case (null) {
        throw (Error.reject("No Data for Principal " #Principal.toText(_owner)));
      };
    };
  };

  public query func getWinningBid(_mintId : Nat32) : async ?Offer {
    _winningBid(_mintId);
  };

  public query ({ caller }) func getClaim() : async Nat {
    _getClaim(caller);
  };

  //Analytics
  public query func ownerDistribution(from : Nat, to : Nat) : async Nat32 {
    var count : Nat32 = 0;
    for ((holder, map) in HashMap.entries(holders)) {
      let size = holders.size;

      if (size >= from and size <= to) {
        count := count + 1;
      };
    };
    count;
  };

  public query func fetchHolders() : async [Principal] {
    let _holders : Buffer.Buffer<Principal> = Buffer.fromArray([]);
    for ((key, value) in HashMap.entries(holders)) {
      _holders.add(key);
    };
    Buffer.toArray(_holders);
  };

  public query func getMintCount() : async Nat32 {
    mintId;
  };

  public query func getTransactionCount() : async Nat32 {
    transactionId;
  };

  public query func getOfferCount() : async Nat32 {
    Nat32.fromNat(offers.size);
  };

  public query func getActiveSaleCount() : async Nat32 {
    Nat32.fromNat(sales.size);
  };

  public query func getActiveBidCount() : async Nat32 {
    Nat32.fromNat(bids.size);
  };

  public query func getSaleHistroyCount() : async Nat32 {
    Nat32.fromNat(priceHistory.size);
  };

  //////////Update Methods///////////

  public shared ({ caller }) func putBlob(blob : Blob) : async Nat32 {
    assert (caller == collectionOwner);
    let currentId = imageId;
    imageId := imageId;
    images := HashMap.insert(images, currentId, n32Hash, n32Equal, blob).0;
    currentId;
  };

  public shared ({ caller }) func startMint(duration : Nat) : async () {
    assert (caller == collectionOwner);
    assert (isMinting == false);
    assert (isWhiteListMinting == false);
    isWhiteListMinting := true;
    await _startWhiteListMinting(duration);
  };

  public shared ({ caller }) func addWhiteList(value : WhiteList) : async WhiteList {
    assert (caller == collectionOwner);
    whiteList := Array.append(whiteList, [value]);
    value;
  };

  public shared ({ caller }) func mint(blob : Blob, recipient : Principal) : async Nat32 {
    assert (caller == collectionOwner);
    if (isMinting == true) {
      let currentId = mintId;
      let _metadata : Metadata = {
        mintId = currentId;
        data = blob;
      };

      //generate NFT
      _mint(_metadata, recipient);
      manifest := HashMap.insert(manifest, currentId, n32Hash, n32Equal, caller).0;
      mintId := mintId + 1;
      currentId;
    } else if (isWhiteListMinting == true) {
      _whiteListMint(caller, recipient, blob);
    } else {
      throw (Error.reject("UNAUTHORIZED"));
    };
  };

  public shared ({ caller }) func bulkMint(blobs : [Blob], recipient : Principal) : async [Nat32] {
    assert (caller == collectionOwner);
    var result : [Nat32] = [];
    if (isMinting == true) {
      for (blob in blobs.vals()) {
        let currentId = mintId;
        mintId := mintId + 1;
        let _metadata : Metadata = {
          mintId = currentId;
          data = blob;
        };
        _mint(_metadata, recipient);
        manifest := HashMap.insert(manifest, currentId, n32Hash, n32Equal, caller).0;
        result := Array.append(result, [currentId]);
      };
    } else if (isWhiteListMinting == true) {
      for (blob in blobs.vals()) {
        let currentId = _whiteListMint(caller, recipient, blob);
        result := Array.append(result, [currentId]);
      };
    } else {
      throw (Error.reject("UNAUTHORIZED"));
    };
    result;
  };

  public shared ({ caller }) func transfer(to : Principal, _mintId : Nat32) : async () {
    assert (_isOwner(caller, _mintId));
    await _remove(_mintId);
    await* _transfer(to, _mintId);
  };

  public shared ({ caller }) func transferFrom(from : Principal, to : Principal, _mintId : Nat32) : async () {
    assert (_isOwner(from, _mintId));
    let exist = HashMap.get(approved, _mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        if (exist == caller) {
          await _remove(_mintId);
          await* _transfer(to, _mintId);
        };
      };
      case (null) {
        throw (Error.reject("Unauthorized " #Nat32.toText(_mintId)));
      };
    };
  };

  public shared ({ caller }) func approve(to : Principal, _mintId : Nat32) : async () {
    assert (_isOwner(caller, _mintId));
    await _remove(_mintId);
    approved := HashMap.insert(approved, _mintId, n32Hash, n32Equal, to).0;
  };

  public shared ({ caller }) func allowance(_owner : Principal, _mintId : Nat32) : async Bool {
    assert (_isOwner(_owner, _mintId));
    let exist = HashMap.get(approved, _mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        exist == caller;
      };
      case (null) {
        false;
      };
    };
  };

  public shared ({ caller }) func claimSales() : async () {
    let amount = _getClaim(caller);
    assert (amount > 0);
    let result = await Dip20.service(Constants.WICP_Canister).transfer(caller, amount);
  };

  public shared ({ caller }) func sell(offerRequest : OfferRequest) : async () {
    assert (_isOwner(caller, offerRequest.mintId));
    await _remove(offerRequest.mintId);
    sales := HashMap.insert(sales, offerRequest.mintId, n32Hash, n32Equal, offerRequest).0;
  };

  public shared ({ caller }) func bulkSell(_offerRequests : [OfferRequest]) : async () {
    for (_offerRequest in _offerRequests.vals()) {
      assert (_isOwner(caller, _offerRequest.mintId));
      await _remove(_offerRequest.mintId);
      sales := HashMap.insert(sales, _offerRequest.mintId, n32Hash, n32Equal, _offerRequest).0;
    };
  };

  public shared ({ caller }) func bid(amount : Nat, _mintId : Nat32) : async () {
    await _bid(amount, _mintId, caller);
  };

  public shared ({ caller }) func auction(auctonRequest : AuctionRequest) : async () {
    assert (_isOwner(caller, auctonRequest.mintId));
    let exist = HashMap.get(auctions, auctonRequest.mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {

      };
      case (null) {
        await _remove(auctonRequest.mintId);
        let _auction = {
          end = Time.now() + (auctonRequest.duration * 1000_000_000);
          mintId = auctonRequest.mintId;
          amount = auctonRequest.amount;
          token = auctonRequest.token;
          icp = auctonRequest.icp;
        };
        auctions := HashMap.insert(auctions, auctonRequest.mintId, n32Hash, n32Equal, _auction).0;
        var timerID = setTimer(
          #seconds(auctonRequest.duration),
          func() : async () {
            await _endAuction(auctonRequest.mintId);
          },
        );
      };
    };
  };

  public shared ({ caller }) func buy(_mintId : Nat32) : async Nat32 {
    let offerRequest = HashMap.get(sales, _mintId, n32Hash, n32Equal);
    let _owner = _getOwner(_mintId);
    switch (offerRequest) {
      case (?offerRequest) {
        let isExpired = _isExpired(offerRequest.expiration);
        assert (isExpired == false);
        let currentId = offerId;
        offerId := offerId + 1;
        let offer = {
          offerId = currentId;
          mintId = offerRequest.mintId;
          seller = _owner;
          buyer = caller;
          amount = offerRequest.amount;
          token = offerRequest.token;
          icp = offerRequest.icp;
          expiration = offerRequest.expiration;
        };
        try {
          await _buy(offer);
        } catch (e) {
          throw (e);
        };
        currentId;
      };
      case (null) {
        throw (Error.reject("No Data for MintId " #Nat32.toText(_mintId)));
      };
    };
  };

  public shared ({ caller }) func bulkBuy(_mintIds : [Nat32]) : async [Nat32] {
    await _bulkBuy(caller, _mintIds);
  };

  public shared ({ caller }) func makeOffer(offerRequest : OfferRequest) : async Nat32 {
    await* _makeOffer(offerRequest, caller);
  };

  public shared ({ caller }) func acceptOffer(_mintId : Nat32, _offerId : Nat32) : async Nat32 {
    let _offers = await* _getOffers(_mintId);
    let offer = Array.find<Offer>(_offers, func(e : Offer) : Bool { e.offerId == _offerId });
    switch (offer) {
      case (?offer) {
        let isExpired = _isExpired(offer.expiration);
        assert (isExpired == false);
        try {
          await _acceptOffer(offer);
        } catch (e) {
          assert (false);
        };
      };
      case (null) {
        throw (Error.reject("No Data for OfferId " #Nat32.toText(_offerId)));
      };
    };
    _offerId;
  };

  public query func http_request(request : Http.Request) : async Http.Response {
    let path = Iter.toArray(Text.tokens(request.url, #text("/")));
    if (path.size() == 1) {
      switch (path[0]) {
        case (_) return return Http.BAD_REQUEST();
      };
    } else if (path.size() == 2) {
      switch (path[0]) {
        case ("image") return _imageResponse(path[1]);
        case ("metaData") return _metaDataResponse(path[1]);
        case (_) return return Http.BAD_REQUEST();
      };
    } else if (path.size() == 3) {
      switch (path[0]) {
        case (_) return return Http.BAD_REQUEST();
      };
    } else {
      return Http.BAD_REQUEST();
    };
  };

  //////////PRIVATE METHODS/////////////////////

  private func _getClaim(owner : Principal) : Nat {
    let _claim = HashMap.get(claims, owner, pHash, pEqual);
    switch (_claim) {
      case (?_claim) {
        _claim;
      };
      case (null) {
        0;
      };
    };
  };

  private func _bulkBuy(caller : Principal, _mintIds : [Nat32]) : async [Nat32] {
    var amount = 0;
    var tempClaims = claims;
    var tempOffers : Buffer.Buffer<Offer> = Buffer.fromArray([]);
    for (_mintId in _mintIds.vals()) {
      let offerRequest = HashMap.get(sales, _mintId, n32Hash, n32Equal);
      let _owner = _getOwner(_mintId);
      switch (offerRequest) {
        case (?offerRequest) {
          let isExpired = _isExpired(offerRequest.expiration);
          assert (isExpired == false);
          let offer : Offer = {
            offerId = 0;
            mintId = offerRequest.mintId;
            seller = _owner;
            buyer = caller;
            amount = offerRequest.amount;
            token = offerRequest.token;
            icp = offerRequest.icp;
            expiration = null;
          };
          tempOffers.add(offer);
          await* _transfer(Principal.fromActor(this), _mintId);
          var claimAmount = _getClaim(_owner);
          amount := amount + offerRequest.icp;
          claimAmount := claimAmount + offerRequest.icp;
          tempClaims := HashMap.insert(tempClaims, _owner, pHash, pEqual, claimAmount).0;
        };
        case (null) {
          throw (Error.reject("No Data for MintId " #Nat32.toText(_mintId)));
        };
      };
    };
    let allowance = await Dip20.service(Constants.WICP_Canister).allowance(caller, Principal.fromActor(this));
    if (amount > allowance) throw (Error.reject("Insufficient Allowance "));
    let royalties = Float.mul(Utils.natToFloat(amount), royalty);
    let _amount = amount - Utils.floatToNat(royalties);
    let result = await Dip20.service(Constants.WICP_Canister).transferFrom(caller, Principal.fromActor(this), _amount);
    switch (result) {
      case (#Ok(value)) {
        let royaltyResult = await Dip20.service(Constants.WICP_Canister).transfer(collectionCreator, Utils.floatToNat(royalties));
        claims := tempClaims;
        for (id in _mintIds.vals()) {
          await* _transfer(caller, id);
          let offerRequest = HashMap.get(sales, id, n32Hash, n32Equal);
          await _remove(id);
          let _owner = _getOwner(id);
          switch (offerRequest) {
            case (?offerRequest) {
              let currentOfferId = offerId + 1;
              offerId := currentOfferId;
              let offer : Offer = {
                offerId = currentOfferId;
                mintId = offerRequest.mintId;
                seller = Principal.fromActor(this);
                buyer = caller;
                amount = offerRequest.amount;
                token = offerRequest.token;
                icp = offerRequest.icp;
                expiration = null;
              };
              _updatePriceHistory(offer);
            };
            case (null) {
              throw (Error.reject("No Data for MintId " #Nat32.toText(id)));
            };
          };
        };
        _mintIds;
      };
      case (#Err(value)) {
        let _tempOffers = Buffer.toArray(tempOffers);
        for (offer in _tempOffers.vals()) {
          let _offerRequest = {
            mintId = offer.mintId;
            amount = offer.amount;
            token = offer.token;
            icp = offer.icp;
            expiration = offer.expiration;
          };
          sales := HashMap.insert(sales, offer.mintId, n32Hash, n32Equal, _offerRequest).0;
          await* _transfer(offer.seller, offer.mintId);
        };
        [];
      };
    };
  };

  private func _whiteListMint(caller : Principal, recipient : Principal, blob : Blob) : Nat32 {
    assert (_isWhiteList(caller));
    let currentId = mintId;
    mintId := mintId + 1;
    let _metadata : Metadata = {
      mintId = currentId;
      data = blob;
    };
    _mint(_metadata, recipient);
    manifest := HashMap.insert(manifest, currentId, n32Hash, n32Equal, caller).0;
    currentId;
  };

  private func _startWhiteListMinting(duration : Nat) : async () {
    var _whiteList = List.fromArray(whiteList);
    let pop = List.pop(_whiteList);
    currentWhiteList := pop.0;
    whiteList := List.toArray(pop.1);
    switch (currentWhiteList) {
      case (?currentWhiteList) {
        ignore setTimer(
          #seconds(currentWhiteList.duration),
          func() : async () {
            await _startWhiteListMinting(duration);
          },
        );
      };
      case (null) {
        isMinting := true;
        isWhiteListMinting := false;
        ignore setTimer(
          #seconds(duration),
          func() : async () {
            isMinting := false;
            _closeMint();
          },
        );
      };
    };
  };

  private func _closeMint() {
    collectionOwner := Principal.fromActor(this);
  };

  private func _natResponse(value : Nat) : Http.Response {
    let json = #Number(value);
    let blob = Text.encodeUtf8(JSON.show(json));
    let response : Http.Response = {
      status_code = 200;
      headers = [("Content-Type", "application/json")];
      body = blob;
      streaming_strategy = null;
    };
  };

  private func _blobResponse(blob : Blob) : Http.Response {
    let response : Http.Response = {
      status_code = 200;
      headers = [("Content-Type", "application/json")];
      body = blob;
      streaming_strategy = null;
    };
  };

  private func _imageResponse(value : Text) : Http.Response {
    let exist = HashMap.get(metaData, Utils.textToNat32(value), n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        let response : Http.Response = {
          status_code = 200;
          headers = [("Content-Type", "image/png")];
          body = exist.data;
          streaming_strategy = null;
        };
      };
      case (null) {
        return Http.BAD_REQUEST();
      };
    };
  };

  private func _metaDataResponse(value : Text) : Http.Response {
    let exist = HashMap.get(metaData, Utils.textToNat32(value), n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        let response : Http.Response = {
          status_code = 200;
          headers = [("Content-Type", "application/json")];
          body = exist.data;
          streaming_strategy = null;
        };
      };
      case (null) {
        return Http.BAD_REQUEST();
      };
    };
  };

  private func _textResponse(value : Text) : Http.Response {
    let json = #String(value);
    let blob = Text.encodeUtf8(JSON.show(json));
    let response : Http.Response = {
      status_code = 200;
      headers = [("Content-Type", "application/json")];
      body = blob;
      streaming_strategy = null;
    };
  };

  private func _jsonResponse(value : [(Text, JSON)]) : Http.Response {
    let json = #Object(value);
    let blob = Text.encodeUtf8(JSON.show(json));
    let response : Http.Response = {
      status_code = 200;
      headers = [("Content-Type", "application/json")];
      body = blob;
      streaming_strategy = null;
    };
  };

  ///Private Methods
  private func _getOwner(_mintId : Nat32) : Principal {
    let _owner = HashMap.get(manifest, _mintId, n32Hash, n32Equal);
    switch (_owner) {
      case (?_owner) {
        _owner;
      };
      case (null) {
        assert (true);
        Principal.fromActor(this);
      };
    };
  };

  private func _fetchPriceHistory(_mintId : Nat32) : [Price] {
    let exist = HashMap.get(priceHistory, _mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        StableBuffer.toArray(exist);
      };
      case (null) { [] };
    };
  };

  private func _getOffers(_mintId : Nat32) : async* [Offer] {
    let exist = HashMap.get(offers, _mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        exist;
      };
      case (null) {
        throw (Error.reject("No Data for MintId " #Nat32.toText(_mintId)));
      };
    };
  };

  private func _mint(data : Metadata, _owner : Principal) {
    metaData := HashMap.insert(metaData, data.mintId, n32Hash, n32Equal, data).0;
    let exist = HashMap.get(holders, _owner, pHash, pEqual);

    switch (exist) {
      case (?exist) {
        let tempMap = HashMap.insert(exist, data.mintId, n32Hash, n32Equal, data).0;
        holders := HashMap.insert(holders, _owner, pHash, pEqual, tempMap).0;
        metaData := HashMap.insert(metaData, data.mintId, n32Hash, n32Equal, data).0;
      };
      case (null) {
        var tempMap = HashMap.empty<Nat32, Metadata>();
        tempMap := HashMap.insert(tempMap, data.mintId, n32Hash, n32Equal, data).0;
        holders := HashMap.insert(holders, _owner, pHash, pEqual, tempMap).0;
        metaData := HashMap.insert(metaData, data.mintId, n32Hash, n32Equal, data).0;
      };
    };
  };

  private func _makeOffer(offerRequest : OfferRequest, caller : Principal) : async* Nat32 {
    let exist = HashMap.get(metaData, offerRequest.mintId, n32Hash, n32Equal);
    let _owner = _getOwner(offerRequest.mintId);
    switch (exist) {
      case (?exist) {
        let currentId = offerId;
        offerId := offerId + 1;
        let offer = {
          offerId = currentId;
          mintId = offerRequest.mintId;
          seller = _owner;
          buyer = caller;
          amount = offerRequest.amount;
          token = offerRequest.token;
          icp = offerRequest.icp;
          expiration = offerRequest.expiration;
        };
        var _offers = await* _getOffers(offerRequest.mintId);
        _offers := Array.append(_offers, [offer]);
        offers := HashMap.insert(offers, currentId, n32Hash, n32Equal, _offers).0;
        currentId;
      };
      case (null) {
        throw (Error.reject("No Data for mintId " #Nat32.toText(offerRequest.mintId)));
      };
    };
  };

  private func _endAuction(_mintId : Nat32) : async () {
    let exist = HashMap.get(winningBids, _mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        winningBids := HashMap.remove(winningBids, _mintId, n32Hash, n32Equal).0;
        await _acceptOffer(exist);
      };
      case (null) {
        throw (Error.reject("No data for winning bid " #Nat32.toText(_mintId)));
      };
    };
  };

  private func _bid(amount : Nat, _mintId : Nat32, buyer : Principal) : async () {
    let exist = HashMap.get(bids, _mintId, n32Hash, n32Equal);
    let _auction = HashMap.get(auctions, _mintId, n32Hash, n32Equal);
    let _winningBid = HashMap.get(winningBids, _mintId, n32Hash, n32Equal);
    let _owner = _getOwner(_mintId);
    switch (_auction) {
      case (?_auction) {
        let offer : Offer = {
          offerId = 0;
          mintId = _mintId;
          seller = _owner;
          buyer = buyer;
          amount = amount;
          token = ?_auction.token;
          icp = _auction.icp;
          expiration = null;
        };
        switch (_winningBid) {
          case (?_winningBid) {
            if (offer.amount > _winningBid.amount) {
              await _tokenTransferFrom(offer);
              await _tokenTransfer(_winningBid, _winningBid.buyer);
              winningBids := HashMap.insert(winningBids, _mintId, n32Hash, n32Equal, offer).0;
              switch (exist) {
                case (?exist) {
                  let tempMap = HashMap.insert(exist, _owner, pHash, pEqual, offer).0;
                  bids := HashMap.insert(bids, _mintId, n32Hash, n32Equal, tempMap).0;
                };
                case (null) {
                  var tempMap = HashMap.empty<Principal, Offer>();
                  tempMap := HashMap.insert(tempMap, buyer, pHash, pEqual, offer).0;
                  bids := HashMap.insert(bids, _mintId, n32Hash, n32Equal, tempMap).0;
                };
              };
            };
          };
          case (null) {
            if (offer.amount >= _auction.amount) {
              await _tokenTransferFrom(offer);
              winningBids := HashMap.insert(winningBids, _mintId, n32Hash, n32Equal, offer).0;
              switch (exist) {
                case (?exist) {
                  let tempMap = HashMap.insert(exist, buyer, pHash, pEqual, offer).0;
                  bids := HashMap.insert(bids, _mintId, n32Hash, n32Equal, tempMap).0;
                };
                case (null) {
                  var tempMap = HashMap.empty<Principal, Offer>();
                  tempMap := HashMap.insert(tempMap, buyer, pHash, pEqual, offer).0;
                  bids := HashMap.insert(bids, _mintId, n32Hash, n32Equal, tempMap).0;
                };
              };
            };
          };
        };
      };
      case (null) {
        throw (Error.reject("No Auction for mintId " #Nat32.toText(_mintId)));
      };
    };
  };

  private func _transfer(to : Principal, _mintId : Nat32) : async* () {
    let from = _getOwner(_mintId);
    let exist = HashMap.get(holders, from, pHash, pEqual);
    let exist2 = HashMap.get(holders, to, pHash, pEqual);
    switch (exist) {
      case (?exist) {
        switch (exist2) {
          case (?exist2) {
            let tempMap = HashMap.remove(exist, _mintId, n32Hash, n32Equal);
            switch (tempMap.1) {
              case (?value) {
                holders := HashMap.insert(holders, from, pHash, pEqual, tempMap.0).0;
                let tempMap2 = HashMap.insert(exist2, _mintId, n32Hash, n32Equal, value);
                holders := HashMap.insert(holders, to, pHash, pEqual, tempMap2.0).0;
              };
              case (null) {
                throw (Error.reject("No Data for mintId " #Nat32.toText(_mintId)));
              };
            };
          };
          case (null) {
            let tempMap = HashMap.remove(exist, _mintId, n32Hash, n32Equal);
            switch (tempMap.1) {
              case (?value) {
                holders := HashMap.insert(holders, from, pHash, pEqual, tempMap.0).0;
                var tempMap2 = HashMap.empty<Nat32, Metadata>();
                tempMap2 := HashMap.insert(tempMap2, _mintId, n32Hash, n32Equal, value).0;
                holders := HashMap.insert(holders, to, pHash, pEqual, tempMap2).0;
              };
              case (null) {
                throw (Error.reject("No Data for mintId " #Nat32.toText(_mintId)));
              };
            };
          };
        };
      };
      case (null) {
        throw (Error.reject("Invalid Holder"));
      };
    };
    await _remove(_mintId);
    manifest := HashMap.insert(manifest, _mintId, n32Hash, n32Equal, to).0;
    let currentId = transactionId;
    transactionId := transactionId + 1;
    let transaction = {
      from = from;
      to = to;
      mintId = _mintId;
      createdAt = Time.now();
    };
    ledger := HashMap.insert(ledger, transactionId, n32Hash, n32Equal, transaction).0;
  };

  private func _remove(_mintId : Nat32) : async () {
    let exist = HashMap.get(winningBids, _mintId, n32Hash, n32Equal);
    switch (exist) {
      case (?exist) {
        await _tokenTransfer(exist, exist.buyer);
      };
      case (null) {

      };
    };
    offers := HashMap.remove(offers, _mintId, n32Hash, n32Equal).0;
    approved := HashMap.remove(approved, _mintId, n32Hash, n32Equal).0;
    sales := HashMap.remove(sales, _mintId, n32Hash, n32Equal).0;
    bids := HashMap.remove(bids, _mintId, n32Hash, n32Equal).0;
    winningBids := HashMap.remove(winningBids, _mintId, n32Hash, n32Equal).0;
    auctions := HashMap.remove(auctions, _mintId, n32Hash, n32Equal).0;
  };

  private func _acceptOffer(offer : Offer) : async () {
    await _tokenTransfer(offer, offer.seller);
    await* _transfer(offer.buyer, offer.mintId)

  };

  private func _updatePriceHistory(offer : Offer) {
    let exist = HashMap.get(priceHistory, offer.mintId, n32Hash, n32Equal);
    let now = Time.now();
    switch (exist) {
      case (?exist) {
        let _price : Price = {
          offer = offer;
          timeStamp = now;
        };
        StableBuffer.add(exist, _price);
        priceHistory := HashMap.insert(priceHistory, offer.mintId, n32Hash, n32Equal, exist).0;
      };
      case (null) {
        let _price : Price = {
          offer = offer;
          timeStamp = now;
        };
        let b = StableBuffer.init<Price>();
        StableBuffer.add(b, _price);
        priceHistory := HashMap.insert(priceHistory, offer.mintId, n32Hash, n32Equal, b).0;
      };
    };
  };

  private func _buy(offer : Offer) : async () {
    let _allowance = await _tokenAllowance(offer);
    assert (_allowance >= offer.amount);
    await _tokenTransferFromRoyalties(offer);
    await* _transfer(offer.buyer, offer.mintId);
    _updatePriceHistory(offer);
  };

  private func _winningBid(_mintId : Nat32) : ?Offer {
    HashMap.get(winningBids, _mintId, n32Hash, n32Equal);
  };

  private func _tokenAllowance(offer : Offer) : async Nat {
    switch (offer.token) {
      case (?token) {
        switch (token) {
          case (#Dip20_EXT(value)) {
            await Dip20_EXT.service(value).allowance(offer.buyer, Principal.fromActor(this));
          };
          case (#Dip20(value)) {
            await Dip20.service(value).allowance(offer.buyer, Principal.fromActor(this));
          };
          case (#IRC2(value)) {
            let now = Time.now();
            let args = {
              account = { owner = offer.buyer; subaccount = null };
              spender = Principal.fromActor(this);

            };
            let result = await ICRC2.service(value).icrc2_allowance(args);
            let expires_at = Nat64.toNat(result.expires_at) + icrc2Buffer;
            assert (expires_at < now);
            result.allowance;

          };
          case (#EXT(value)) {
            throw (Error.reject("No Implmentation"));
          };
        };
      };
      case (null) {
        await Dip20.service(Constants.WICP_Canister).allowance(offer.buyer, Principal.fromActor(this));
      };
    };
  };

  private func _isOwner(caller : Principal, _mintId : Nat32) : Bool {
    let exist = HashMap.get(holders, caller, pHash, pEqual);
    switch (exist) {
      case (?exist) {
        let exist2 = HashMap.get(exist, _mintId, n32Hash, n32Equal);
        switch (exist2) {
          case (?exist2) {
            true;
          };
          case (null) {
            false;
          };
        };
      };
      case (null) {
        false;
      };
    };
  };

  private func _isExpired(time : ?Time.Time) : Bool {
    let now = Time.now();
    switch (time) {
      case (?time) {
        time < now;
      };
      case (null) {
        false;
      };
    };
  };

  private func _tokenTransfer(offer : Offer, to : Principal) : async () {
    assert (offer.amount > 0);
    let royalties = Float.mul(Utils.natToFloat(offer.amount), royalty);
    switch (offer.token) {
      case (?token) {
        switch (token) {
          case (#Dip20_EXT(value)) {
            let _amount = offer.amount - Utils.floatToNat(royalties);
            let result = await Dip20_EXT.service(value).transfer(to, _amount);
            let royaltyResult = await Dip20_EXT.service(value).transfer(collectionCreator, Utils.floatToNat(royalties));
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };
          };
          case (#Dip20(value)) {
            let _amount = offer.amount - Utils.floatToNat(royalties);
            let result = await Dip20.service(value).transfer(to, _amount);
            let royaltyResult = await Dip20.service(value).transfer(collectionCreator, Utils.floatToNat(royalties));
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };
          };
          case (#IRC2(value)) {
            let _amount = offer.amount - Utils.floatToNat(royalties);
            let now = Time.now();

            let from = { owner = offer.seller; subaccount = null };
            let to = { owner = offer.buyer; subaccount = null };
            let toRoyalties = { owner = collectionCreator; subaccount = null };

            let args : ICRC2.TransferArgs = {
              from = from;
              to = to;
              amount = _amount;
              fee = 0;
              memo = Text.encodeUtf8("");
              created_at_time = 0;

            };

            let argsRoyalties : ICRC2.TransferArgs = {
              from = from;
              to = toRoyalties;
              amount = Utils.floatToNat(royalties);
              fee = 0;
              memo = Text.encodeUtf8("");
              created_at_time = 0;

            };

            let result = await ICRC2.service(value).icrc2_transfer_from(args);
            let royaltyResult = await ICRC2.service(value).icrc2_transfer_from(argsRoyalties);

            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };

          };
          case (#EXT(value)) {
            throw (Error.reject("No Implmentation"));
          };
        };
      };
      case (null) {
        let _amount = offer.amount - Utils.floatToNat(royalties);
        let result = await Dip20.service(Constants.WICP_Canister).transfer(to, _amount);
        let royaltyResult = await Dip20.service(Constants.WICP_Canister).transfer(collectionCreator, Utils.floatToNat(royalties));
        switch (result) {
          case (#Ok(value)) {

          };
          case (#Err(value)) {
            throw (Error.reject("Token Transfer Error"));
          };
        };
      };
    };
  };

  private func _tokenTransferFrom(offer : Offer) : async () {
    assert (offer.amount > 0);
    switch (offer.token) {
      case (?token) {
        switch (token) {
          case (#Dip20_EXT(value)) {
            let result = await Dip20_EXT.service(value).transferFrom(offer.buyer, Principal.fromActor(this), offer.amount);
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };
          };
          case (#Dip20(value)) {
            let result = await Dip20.service(value).transferFrom(offer.buyer, Principal.fromActor(this), offer.amount);
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };
          };
          case (#IRC2(value)) {
            let now = Time.now();

            let from = { owner = offer.buyer; subaccount = null };
            let to = { owner = Principal.fromActor(this); subaccount = null };
            let toRoyalties = { owner = collectionCreator; subaccount = null };

            let args : ICRC2.TransferArgs = {
              from = from;
              to = to;
              amount = offer.amount;
              fee = 0;
              memo = Text.encodeUtf8("");
              created_at_time = 0;

            };

            let result = await ICRC2.service(value).icrc2_transfer_from(args);
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };

          };
          case (#EXT(value)) {
            throw (Error.reject("No Implmentation"));
          };
        };
      };
      case (null) {
        let result = await Dip20.service(Constants.WICP_Canister).transferFrom(offer.buyer, Principal.fromActor(this), offer.amount);
        switch (result) {
          case (#Ok(value)) {

          };
          case (#Err(value)) {
            throw (Error.reject("Token Transfer Error"));
          };
        };
      };
    };
  };

  private func _tokenTransferFromRoyalties(offer : Offer) : async () {
    let royalties = Float.mul(Utils.natToFloat(offer.amount), royalty);
    switch (offer.token) {
      case (?token) {
        switch (token) {
          case (#Dip20_EXT(value)) {
            let _amount = offer.amount - Utils.floatToNat(royalties);
            let result = await Dip20_EXT.service(value).transferFrom(offer.buyer, offer.seller, _amount);
            let royaltyResult = await Dip20_EXT.service(value).transferFrom(offer.buyer, collectionCreator, Utils.floatToNat(royalties));
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };
          };
          case (#Dip20(value)) {
            let _amount = offer.amount - Utils.floatToNat(royalties);
            let result = await Dip20.service(value).transferFrom(offer.buyer, offer.seller, _amount);
            let royaltyResult = await Dip20.service(value).transferFrom(offer.buyer, collectionCreator, Utils.floatToNat(royalties));
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };
          };
          case (#IRC2(value)) {
            let now = Time.now();

            let from = { owner = offer.buyer; subaccount = null };
            let to = { owner = Principal.fromActor(this); subaccount = null };
            let toRoyalties = { owner = collectionCreator; subaccount = null };

            let args : ICRC2.TransferArgs = {
              from = from;
              to = to;
              amount = offer.amount;
              fee = 0;
              memo = Text.encodeUtf8("");
              created_at_time = 0;

            };

            let argsRoyalties : ICRC2.TransferArgs = {
              from = from;
              to = toRoyalties;
              amount = Utils.floatToNat(royalties);
              fee = 0;
              memo = Text.encodeUtf8("");
              created_at_time = 0;

            };

            let result = await ICRC2.service(value).icrc2_transfer_from(args);
            let royaltyResult = await ICRC2.service(value).icrc2_transfer_from(argsRoyalties);
            switch (result) {
              case (#Ok(value)) {

              };
              case (#Err(value)) {
                throw (Error.reject("Token Transfer Error"));
              };
            };

          };
          case (#EXT(value)) {
            throw (Error.reject("No Implmentation"));
          };
        };
      };
      case (null) {
        let _amount = offer.amount - Utils.floatToNat(royalties);
        let result = await Dip20.service(Constants.WICP_Canister).transferFrom(offer.buyer, offer.seller, _amount);
        let royaltyResult = await Dip20.service(Constants.WICP_Canister).transferFrom(offer.buyer, collectionCreator, Utils.floatToNat(royalties));
        switch (result) {
          case (#Ok(value)) {

          };
          case (#Err(value)) {
            throw (Error.reject("Token Transfer Error"));
          };
        };
      };
    };
  };

  private func _isWhiteList(caller : Principal) : Bool {
    switch (currentWhiteList) {
      case (?currentWhiteList) {
        let exist = Array.find(currentWhiteList.value, func(e : Principal) : Bool { caller == e });
        switch (exist) {
          case (?exist) true;
          case (null) false;
        };
      };
      case (null) {
        false;
      };
    };
  };

  // Returns the cycles received up to the capacity allowed
  public func wallet_receive() : async { accepted : Nat64 } {
    let amount = Cycles.available();
    let limit : Nat = capacity - cyclesBalance;
    let accepted = if (amount <= limit) amount else limit;
    let deposit = Cycles.accept(accepted);
    assert (deposit == accepted);
    cyclesBalance += accepted;
    { accepted = Nat64.fromNat(accepted) };
  };

};
