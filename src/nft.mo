import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Cycles "mo:base/ExperimentalCycles";
import Hash "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import MapHelper "mapHelper";
import Nat "mo:base/Nat";
import NftTypes "types";
import Http "httpTypes";
import Option "mo:base/Option";
import Prim "mo:⛔";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/TrieSet";
import Nat32 "mo:base/Nat32";

// Support multiple assets
// Support copyright tax

shared({ caller = hub }) actor class Nft() = this {
    var MAX_RESULT_SIZE_BYTES = 1_000_000; //1MB Default
    var HTTP_STREAMING_SIZE_BYTES = 1_900_000;

    stable var CONTRACT_METADATA : NftTypes.ContractMetadata = {name = "none"; symbol = "none"};
    stable var INITALIZED : Bool = false;

    stable var TOPUP_AMOUNT = 2_000_000;
    stable var AUTHORIZED_LIMIT = 25;
    stable var BROKER_CALL_LIMIT = 25;
    stable var BROKER_FAILED_CALL_LIMIT = 25;

    stable var seq : Nat = 0;
    stable var payloadSize : Nat = 0;

    //Record an seq corresponding to one or more NFTs, Text as a key is nftid
    stable var nftEntries : [(Text, NftTypes.Nft)] = [];
    let nfts = HashMap.fromIter<Text, NftTypes.Nft>(nftEntries.vals(), 10, Text.equal, Text.hash);

    stable var staticAssetsEntries : [(Text, NftTypes.StaticAsset)] = [];
    let staticAssets = HashMap.fromIter<Text, NftTypes.StaticAsset>(staticAssetsEntries.vals(), 10, Text.equal, Text.hash);

    //An nftid corresponds to an owner ID
    stable var nftToOwnerEntries : [(Text, Principal)] = [];
    let nftToOwner = HashMap.fromIter<Text, Principal>(nftToOwnerEntries.vals(), 15, Text.equal, Text.hash);

    //
    stable var ownerToNftEntries : [(Principal, [Text])] = [];
    let ownerToNft = HashMap.fromIter<Principal, [Text]>(ownerToNftEntries.vals(), 15, Principal.equal, Principal.hash);

    stable var authorizedEntries : [(Text, [Principal])] = [];
    let authorized = HashMap.fromIter<Text, [Principal]>(authorizedEntries.vals(), 15, Text.equal, Text.hash);
    
    stable var contractOwners : [Principal] = [hub];
    
    stable var messageBrokerCallback : ?NftTypes.EventCallback = null;
    stable var messageBrokerCallsSinceLastTopup : Nat = 0;
    stable var messageBrokerFailedCalls : Nat = 0;

    //private var usersTokens = HashMap.HashMap<Principal, UserTokens>(1, Principal.equal, Principal.hash);
    var stagedNftData = HashMap.HashMap<Principal , Buffer.Buffer<Blob>>(1, Principal.equal, Principal.hash);
    var stagedAssetData = Buffer.Buffer<Blob>(0);

    system func preupgrade() {
        nftEntries := Iter.toArray(nfts.entries());
        staticAssetsEntries := Iter.toArray(staticAssets.entries());
        nftToOwnerEntries := Iter.toArray(nftToOwner.entries());
        ownerToNftEntries := Iter.toArray(ownerToNft.entries());
        authorizedEntries := Iter.toArray(authorized.entries());
    };

    system func postupgrade() {
        nftEntries := [];
        staticAssetsEntries := [];
        nftToOwnerEntries := [];
        ownerToNftEntries := [];
        authorizedEntries := [];
    };

    // mutil token standard

    // Returns the number of categories and the total number of NFTs
    public query func getTotalMinted() : async (Nat, Nat) {
        var totalSize : Nat = 0;
        for ((k, v) in nfts.entries()){
            totalSize  += Nat32.toNat(v.amount);
        };
        return (nfts.size(), totalSize);
    };

    public shared ({caller = caller}) func mint(egg : NftTypes.NftEgg) : async [Text] {
        assert _isOwner(caller);
        return await _mint(caller, egg)
    };

    public shared({caller = caller}) func burn(id : Text) : async (NftTypes.BurnResult){
        return _burn(caller, id);
    };

    public func balanceOf(p : Principal) : async [Text] {
        return _balanceOf(p)
    };

    public shared ({caller = caller}) func transfer(transferRequest : NftTypes.TransferRequest) : async NftTypes.TransferResult {
        return await _transfer(caller, transferRequest);
    };

    public shared ({caller = caller}) func authorize(authorizeRequest : NftTypes.AuthorizeRequest) : async NftTypes.AuthorizeResult {
        return await _authorize(caller, authorizeRequest);
    };

    public shared({caller = caller}) func tokenByID(id : Text) : async NftTypes.NftResult {
        let nftID = NftTypes.TextToNFTID(id);

        switch(nfts.get(nftID.seq)) {
            case null return #err(#NotFound);
            case (?v) {
                if (nftID.index != NftTypes.INVALID_INDEX) {
                    assert(v.amount > nftID.index);

                    if (v.isPrivate) {
                        switch(_isAuthorized(caller, id)) {
                            case (#err(v)) {
                                if (not _isOwner(caller)) return #err(v);
                            };
                            case _ {};
                        };
                    };
                    var payloadResult : NftTypes.PayloadResult = #Complete(v.payload[0]);

                    if (v.payload.size() > 1) {
                        payloadResult := #Chunk({data = v.payload[0]; totalPages = v.payload.size(); nextPage = ?1});
                    };

                    #ok({
                        contentType = v.contentType;
                        createdAt = v.createdAt;
                        id = id;
                        owner = _ownerOf(id);
                        payload = payloadResult;
                        properties = v.properties;
                        number = 1;
                    });     
        
                } else {
                    return #err(#NotFound);
                };                          
            };
        };

    };
 
    // public interface
    public shared({caller = caller}) func init(owners : [Principal], metadata : NftTypes.ContractMetadata) : async () {
        assert not INITALIZED and caller == hub;
        contractOwners := Array.append(contractOwners, owners);
        CONTRACT_METADATA := metadata;
        INITALIZED := true;
    };

    public func getMetadata() : async NftTypes.ContractMetadata {
        return CONTRACT_METADATA;
    };

    public func ownerOf(id : Text) : async NftTypes.OwnerOfResult {
        switch(nftToOwner.get(id)) {
            case (null) return #err(#NotFound);
            case (?v) return #ok(v);
        };
    };
    public shared({caller = caller}) func writeStaged(data : NftTypes.StagedWrite) : async () {
        assert _isOwner(caller);

        switch (data) {
            case (#Init(v)) {
                stagedNftData.put(caller, Buffer.Buffer<Blob>(v.size));
            };
            case (#Chunk({chunk = chunk; callback = callback})) {
                switch(stagedNftData.get(caller)){
                    case (?value){
                        value.add(chunk);
                        stagedNftData.put(caller, value);
                        ignore _fireAndForgetCallback(callback);
                    };
                    case (_) {
                        //You should use init
                        assert(false);
                    };
                };
            };
        };
    };

    public shared ({caller = caller}) func getContractInfo() : async NftTypes.ContractInfo {
        assert _isOwner(caller);
        return _contractInfo();
    };

    public query ({caller = caller }) func listAssets() : async [(Text, Text, Nat)] {
        assert _isOwner(caller);
        let assets : [var (Text, Text, Nat)] = Array.init<(Text, Text, Nat)>(staticAssets.size(), ("","",0));

        var idx = 0;

        for ((k, v) in staticAssets.entries()) {
            var sum = 0;
            Iter.iterate<Blob>(v.payload.vals(), func(x, _) {sum += x.size()});
            assets[idx] := (k, v.contentType, sum);
            idx += 1;
        };

        return Array.freeze(assets);
    };

    public shared ({caller = caller}) func assetRequest(data : NftTypes.AssetRequest) : async (){
        assert _isOwner(caller);

        switch(data) {
            case(#Put(v)) {
                switch(v.payload) {
                    case(#Payload(data)) {
                        staticAssets.put(v.name, {contentType = v.contentType; payload = [data]});
                    };
                    case (#StagedData) {
                        // #Put : {name : Text; contentType : Text; payload : {#Payload : Blob; #StagedData}; callback : ?Callback};
                        staticAssets.put(v.name, {contentType = v.contentType; payload = stagedAssetData.toArray()});
                        stagedAssetData := Buffer.Buffer(0);
                    };
                };
            };
            case(#Remove({name = name; callback = callback})) {
                staticAssets.delete(name);
                ignore _fireAndForgetCallback(callback);
            };
            case(#StagedWrite(v)) {
                switch(v) {
                    case (#Init({size = size; callback = callback})) {
                        stagedAssetData := Buffer.Buffer(size);
                        ignore _fireAndForgetCallback(callback);
                    };
                    case (#Chunk({chunk = chunk; callback = callback})) {
                        stagedAssetData.add(chunk);
                         ignore _fireAndForgetCallback(callback);
                    };
                }
            }
        };
    };

    public shared ({caller = caller}) func updateContractOwners(updateOwnersRequest : NftTypes.UpdateOwnersRequest) : async NftTypes.UpdateOwnersResult {
        if (not _isOwner(caller)) {
            return #err(#Unauthorized);
        };

        switch(updateOwnersRequest.isAuthorized) {
            case (true) {_addOwner(updateOwnersRequest.user)};
            case (false) {_removeOwner(updateOwnersRequest.user)};
        };

        ignore _emitEvent({
            createdAt = Time.now();
            event = #ContractEvent(#ContractAuthorize({user = updateOwnersRequest.user; isAuthorized = updateOwnersRequest.isAuthorized}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });

        return #ok();
    };

    public shared func isAuthorized(id : Text, user : Principal) : async Bool {
        switch (_isAuthorized(user, id)) {
            case (#ok()) return true;
            case (_) return false;
        };
    };

    public shared func getAuthorized(id : Text) : async [Principal] {
        switch (authorized.get(id)) {
            case (?v) return v;
            case _ return [];
        };
    };
    
    public shared ({caller = caller}) func tokenChunkByID(id : Text, page : Nat) : async NftTypes.ChunkResult {
        let nftID = NftTypes.TextToNFTID(id);
        assert(nftID.index != NftTypes.INVALID_INDEX);

        switch (nfts.get(nftID.seq)) {
            case null return #err(#NotFound);
            case (?v) {
                assert(v.amount > nftID.index);

                if (v.isPrivate) {
                    switch(_isAuthorized(caller, id)) {
                        case (#err(v)) {
                            if (not _isOwner(caller)) return #err(v);
                        };
                        case _ {};
                    }; 
                };

                let totalPages = v.payload.size();
                if (page > totalPages) {
                    return #err(#InvalidRequest);
                };

                var nextPage : ?Nat = null;
                if (totalPages > page + 1) {
                    nextPage := ?(page + 1);
                };

                #ok({
                    data = v.payload[page];
                    nextPage = nextPage;
                    totalPages = totalPages;
                })
            };
        };
    };

    public shared ({caller = caller}) func updateProperties(request : NftTypes.UpdatePropertyRequest) : async () {
        assert _isOwner(caller); // TODO update to result object
        switch(nfts.get(request.id)) {
            case null return;
            case (?nft) {};
        };
    };

    private func _handlePropertyUpdates(prop : NftTypes.Property, request : [NftTypes.UpdateQuery]) : NftTypes.Property {
        for (q in request.vals()) {
            
        };
        return prop;
    };

    private func _handleUpdateQuery(prop : NftTypes.Property, q : NftTypes.UpdateQuery) : NftTypes.Property {
        if (q.name != prop.name) return prop;
        switch(q.mode) {
            case (#Next(v)) {
                return _handlePropertyUpdates(prop, v);
            };
            case (#Set(v)) {
                if (prop.immutable) return prop; // Throw
                return {
                    name = prop.name;
                    immutable = false;
                    value = v;
                }
            };
        };
    };

    // Insecure Functions
    public shared query func balanceOfInsecure(p : Principal) : async [Text] {
        return _balanceOf(p)
    };

    public shared query func ownerOfInsecure(id : Text) : async NftTypes.OwnerOfResult {
        switch(nftToOwner.get(id)) {
            case (null) return #err(#NotFound);
            case (?v) return #ok(v);
        };
    };

    public shared query func isAuthorizedInsecure(id : Text, user : Principal) : async Bool {
        switch (_isAuthorized(user, id)) {
            case (#ok()) return true;
            case (_) return false;
        };
    };

    public query func getAuthorizedInsecure(id : Text) : async [Principal] {
        switch (authorized.get(id)) {
            case (?v) return v;
            case _ return [];
        };
    };

    public query ({caller = caller}) func getContractInfoInsecure() : async NftTypes.ContractInfo {
        assert _isOwner(caller);
        return _contractInfo();
    };

    public query ({caller = caller}) func queryProperties(propertyQuery : NftTypes.PropertyQueryRequest) : async NftTypes.PropertyQueryResult {
        let nftID = NftTypes.TextToNFTID(propertyQuery.id);
        assert(nftID.index != NftTypes.INVALID_INDEX);
        switch(propertyQuery.mode) {
            case (#All) {
                switch(nfts.get(nftID.seq)) {
                    case (null) {return #err(#NotFound)};
                    case (?v) {                        
                        assert(v.amount > nftID.index);
                      
                        if (v.isPrivate) {
                            switch(_isAuthorized(caller, propertyQuery.id)) {
                                case (#err(v)) return #err(v);
                                case _ {};
                            };
                        };
                        switch(v.properties) {
                            case null {return #ok(null)};
                            case (?properties) {
                                return #ok(?properties)
                            }
                        }
                    };
                }
            };
            case (#Some(v)) {
                return  _handleQueries(caller, nftID, v);
            };
        };
    };

    private func _handleQueries(caller : Principal, nftID : NftTypes.NFTID, query0 : NftTypes.PropertyQuery) : NftTypes.PropertyQueryResult {
        let id = NftTypes.NFTIDToText(nftID);
        switch(nfts.get(nftID.seq)) {
            case (null) return #err(#NotFound);
            case (?v) {
                assert(v.amount > nftID.index);
              
                if (v.isPrivate) {
                    switch(_isAuthorized(caller, id)) {
                        case (#err(v)) {
                            if (not _isOwner(caller)) return #err(v);
                        };
                        case (v) {};
                    }
                };
                switch (v.properties) {
                    case null {return #ok(?{immutable = true; value = #Empty; name = query0.name})};
                    case (?properties) {
                        switch(_handleQuery(properties, query0)){
                            case null {return #ok(null)};
                            case (?v) {return #ok(?v)}
                        };
                    }
                }
            };
        }
    };

    private func _handleQuery(klass : NftTypes.Property, query0 : NftTypes.PropertyQuery) : ?NftTypes.Property {
        if (klass.name == query0.name) {
                switch(query0.next) {
                    case null {
                        return ?{name = klass.name; value = klass.value; immutable = klass.immutable};
                    };
                    case (?vals) {
                        switch(klass.value) {
                            case (#Class(nestedClass)) {
                                var foundProps : [NftTypes.Property] = [];
                                for (next : NftTypes.PropertyQuery in vals.vals()) {
                                    for (prop in nestedClass.vals()) {
                                        switch(_handleQuery(prop, next)) {
                                            case(null){};
                                            case(?v){
                                                foundProps := Array.append(foundProps, [v]);
                                            };
                                        };
                                    };
                                };
                                return ?{name = klass.name; value = #Class(foundProps); immutable = klass.immutable}
                            };
                            case (_) {
                            }; // Only Class has nested props
                        }
                    }
                }
        };
        return null;
    };

    // cycle func
    public shared(msg) func wallet_receive() : async () {
      
        let amount = Cycles.available();
        let accepted = Cycles.accept(amount);
        assert (accepted == amount);
    };

    public shared ({caller = caller})func cycle() : async Nat{
        assert(caller == hub);
        Cycles.balance();
    };

    // Internal Functions
    private func _balanceOf(p : Principal) : [Text] {
        switch (ownerToNft.get(p)) {
            case (?ids){
              ids;     
            };
            case (null) return [];
        };
    };

    // mint a new Token, the amount of tokens may be one or more
    private func _mint(caller : Principal, egg : NftTypes.NftEgg) : async [Text] {
        let thisId = Nat.toText(seq);
        var size = 0;
        var newIDs :[Text] = [];
        var i : Nat32 = 0;
        let createAt = Time.now();
    
        switch (egg.payload) {
            case (#Payload(v)) {
                nfts.put(thisId, {
                        contentType = egg.contentType;
                        createdAt = createAt;
                        payload = [Blob.fromArray(v)];
                        properties = egg.properties;
                        isPrivate = egg.isPrivate;
                        amount = egg.amount;
                    });
                size += v.size();
            };
            case (#StagedData) {
                var tempPayload : [Blob] = [];
                switch(stagedNftData.get(caller)){
                    case (?value){
                       tempPayload := Array.append<Blob>(tempPayload, value.toArray());
                    };
                    case (_) {
                        //You should use init
                        assert(false);
                    };
                };

                nfts.put(thisId, {
                    contentType = egg.contentType;
                    createdAt = createAt;
                    payload = tempPayload;
                    properties = egg.properties;
                    isPrivate = egg.isPrivate;
                    amount = egg.amount;
                });
                for (x in tempPayload.vals()) {
                    size := size + x.size();
                };
                var buf = Buffer.Buffer<Blob>(0);
                stagedNftData.put(caller, buf);
            };
        };

        payloadSize := payloadSize + size;
        seq := seq + 1;
        var owner = Principal.fromActor(this);

        switch (egg.owner) {
            case (null) {};
            case (?v) {
                owner := v;
            };
        };
      
        // Add the newly minted egg to the NTFs of `owner`.
        var k = 0;
        while (k < Nat32.toNat(egg.amount)){
            k += 1;
            var id : Text = NftTypes.NFTIDToText({seq=thisId; index = Nat32.fromNat(k)});
            switch(ownerToNft.get(owner)){
                case (null) {};
                case (?v){};
            };

            newIDs := Array.append<Text>(newIDs, [id]);
            MapHelper.add<Principal, Text>(ownerToNft, owner, id, MapHelper.textEqual(id));
            nftToOwner.put(id, owner);
        };
        
        ignore _emitEvent({
            createdAt = Time.now();
            event = #ContractEvent(#Mint({id = thisId; owner = owner}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
        return newIDs;
    };

    private func _contractInfo() : NftTypes.ContractInfo {
        return {
            heap_size = Prim.rts_heap_size();
            memory_size = Prim.rts_memory_size();
            max_live_size = Prim.rts_max_live_size();
            nft_payload_size = payloadSize; 
            total_minted = nfts.size(); 
            cycles = Cycles.balance();
            authorized_users = contractOwners
        };
    };

    private func _fireAndForgetCallback(cbMaybe : ?NftTypes.Callback) : async () {
        switch(cbMaybe) {
            case null return;
            case (?cb) {ignore cb()};
        };
    };

    private func _ownerOf(id : Text) : Principal {
        switch(nftToOwner.get(id)) {
            case (null) return Principal.fromActor(this);
            case (?v) return v;
        }
    };

    private func _isOwner(p : Principal) : Bool {
        switch(Array.find<Principal>(contractOwners, func(v) {return v == p})) {
            case (null) return false;
            case (?v) return true;
        };
    };

    private func _addOwner(p : Principal) {
        if (_isOwner(p)) {
            return;
        };
        contractOwners := Array.append(contractOwners, [p]);
    };

    private func _removeOwner(p : Principal) {
        contractOwners := Array.filter<Principal>(contractOwners, func(v) {v != p});
    };

    // Check auth
    // Update owners
    // Remove existing auths
    private func _transfer(caller : Principal, transferRequest : NftTypes.TransferRequest) : async NftTypes.TransferResult {
        assert(transferRequest.id.size() == transferRequest.to.size());
        var self = Principal.fromActor(this);
        var tokenOwner = self;

        for (key in Array.keys<Text>(transferRequest.id)){
            let id = transferRequest.id[key];
            let nftID = NftTypes.TextToNFTID(id);
            let to = transferRequest.to[key];
            switch(nfts.get(nftID.seq)) {
                case null {
                    // todo add to log
                    assert(false)
                };
                case (?v) {}; // Nft Exists
            };

            switch (nftToOwner.get(id)) {             
                case null { };
                case (?realOwner) {
                    tokenOwner := realOwner;
                    if (tokenOwner == to) {
                        // todo add to log
                        assert(false)
                    };
                }
            };

            let isOwnedContractAndCallerOwner = tokenOwner == self and _isOwner(caller);
            
            if (caller != tokenOwner and not isOwnedContractAndCallerOwner) {
                switch(authorized.get(id)) {
                    case null assert(false); //#err(#Unauthorized);
                    case (?users) {
                        switch(Array.find<Principal>(users, func (v : Principal) {return v == caller})) {
                            case null { 
                                // todo add to log
                                assert(false);
                            };//return #err(#Unauthorized);
                            case (?_) {};
                        };
                    };
                };
            };

            // Add the transfered NFT to the NTFs of the recipient.
            MapHelper.add<Principal, Text>(ownerToNft, to, id, MapHelper.textEqual(id));
            // Remove the transfered NFT from the previous NTF owner.
            MapHelper.filter<Principal, Text>(ownerToNft, tokenOwner, id, MapHelper.textNotEqual(id));

            nftToOwner.put(id, to);
            authorized.put(id, []);
            
            ignore _emitEvent({
                createdAt = Time.now();
                event = #NftEvent(#Transfer({from = tokenOwner; to = to; id = id}));
                topupAmount = TOPUP_AMOUNT;
                topupCallback = wallet_receive;
            });
        };
               
        return #ok();
    };

    private func _authorize(caller : Principal, r : NftTypes.AuthorizeRequest) : async NftTypes.AuthorizeResult {
        assert(r.id.size() == r.isAuthorized.size() and r.isAuthorized.size() == r.user.size());

        for( k in Array.keys<Text>(r.id)){
            let id = r.id[k];
            let isAuthorized = r.isAuthorized[k];
            let user = r.user[k];

            switch(_isAuthorized(caller, id)) {
                case (#err(v)) { //todo err to log 
                    Debug.print(debug_show("isAuthorized ret err", v, caller, id));
                    assert(false);
                };
                case (_) {} // Ok;
            };

            switch(isAuthorized) {
                case (true) {
                    switch(MapHelper.addIfNotLimit<Text, Principal>(authorized, id, user, AUTHORIZED_LIMIT, MapHelper.principalEqual(user))) {
                        case true {};
                        case false { 
                            //todo err to log 
                            assert(false);
                        }; //return #err(#AuthorizedPrincipalLimitReached(AUTHORIZED_LIMIT))};
                    };
                };
                case (false) {
                    MapHelper.filter<Text, Principal>(authorized, id, user, func (v : Principal) {v != user});
                };
            };
    
            ignore _emitEvent({
                createdAt = Time.now();
                event = #NftEvent(#Authorize({id = id; user = user; isAuthorized = isAuthorized}));
                topupAmount = TOPUP_AMOUNT;
                topupCallback = wallet_receive;
            });
        };

        return #ok();
    };

    private func _emitEvent(event : NftTypes.EventMessage) : async () {
        let emit = func(broker : NftTypes.EventCallback, msg : NftTypes.EventMessage) : async () {
            try {
                await broker(msg);
                messageBrokerCallsSinceLastTopup := messageBrokerCallsSinceLastTopup + 1;
                messageBrokerFailedCalls := 0;
            } catch(_) {
                messageBrokerFailedCalls := messageBrokerFailedCalls + 1;
                if (messageBrokerFailedCalls > BROKER_FAILED_CALL_LIMIT) {
                    messageBrokerCallback := null;
                };
            };
        };

        switch(messageBrokerCallback) {
            case null return;
            case (?broker) {
                if (messageBrokerCallsSinceLastTopup > BROKER_CALL_LIMIT) {return};
                ignore emit(broker, event);
            };
        };
    };

    private func _isAuthorized(caller : Principal, id : Text) : Result.Result<(), NftTypes.Error> {
        let nftID = NftTypes.TextToNFTID(id);
        switch (nfts.get(nftID.seq)) {
            case null return #err(#NotFound);
            case _ {};
        };
        
        switch (nftToOwner.get(id)) {
            case null {}; // Not owner. Check if authd
            case (?v) {
                if (v == caller) return #ok(); 

                if (v == Principal.fromActor(this)) { // Owner is contract
                    if (_isOwner(caller)) {
                        return #ok();
                    };
                };
            };
        };

        switch(authorized.get(id)) {
            case null return #err(#Unauthorized);
            case (?users) {
                switch(Array.find<Principal>(users, func (v : Principal) {return v == caller})) {
                    case null return #err(#Unauthorized);
                    case (?user) {
                        return #ok() // is Authd!
                    };
                };
            };
        };

        return #err(#Unauthorized);
    };

    public shared ({caller = caller}) func setEventCallback(cb : NftTypes.EventCallback) : async () {
        assert _isOwner(caller);
        messageBrokerCallback := ?cb;
    };

    public shared ({caller = caller}) func getEventCallbackStatus() : async NftTypes.EventCallbackStatus {
        assert _isOwner(caller);
        return {
            callback = messageBrokerCallback;
            callsSinceLastTopup = messageBrokerCallsSinceLastTopup;
            failedCalls = messageBrokerFailedCalls;
            noTopupCallLimit = BROKER_CALL_LIMIT;
            failedCallsLimit = BROKER_FAILED_CALL_LIMIT;
        };
    };

    private func _burn(caller : Principal, id : Text) : (NftTypes.BurnResult){
        let nftID = NftTypes.TextToNFTID(id);
        assert(nftID.index != NftTypes.INVALID_INDEX);

       switch(nftToOwner.get(id)) {
            case (null) return #err(#NotFound);
            case (?v) {
                assert(v == caller);
                nftToOwner.delete(id);
            };
        };

        switch(ownerToNft.get(caller)){
            case (null) return #err(#NotFound);
            case (?v){
                let leftValues = Array.filter<Text>(v, func(element : Text){
                    if (id != element) {
                        return true;
                    };
                    return false;
                });
                if (leftValues.size() > 0){
                    ownerToNft.put(caller, leftValues);
                } else {
                    ownerToNft.delete(caller);
                };
            };
        };

        switch(nfts.get(nftID.seq)) {
            case (null) {return #err(#NotFound)};
            case (?v) {                        
                assert(v.amount > nftID.index);
                
                var newV : NftTypes.Nft = {
                    payload = v.payload;
                    contentType = v.contentType;
                    createdAt = v.createdAt;
                    properties = v.properties;
                    isPrivate = v.isPrivate;
                    amount = v.amount - 1;
                };
                
                if (newV.amount > 0){
                    nfts.put(nftID.seq, newV);
                } else {
                    nfts.delete(nftID.seq);
                };

                #ok();
            };
        };
    };

    // Http Interface

    let NOT_FOUND : Http.Response = {status_code = 404; headers = []; body = Blob.fromArray([]); streaming_strategy = null};
    let BAD_REQUEST : Http.Response = {status_code = 400; headers = []; body = Blob.fromArray([]); streaming_strategy = null};
    let UNAUTHORIZED : Http.Response = {status_code = 401; headers = []; body = Blob.fromArray([]); streaming_strategy = null};

    public query func http_request(request : Http.Request) : async Http.Response {
        Debug.print(request.url);
        let path = Iter.toArray(Text.tokens(request.url, #text("/")));
        
        if (path.size() == 0) {
            return _handleAssets("/index.html");
        };

        if (path[0] == "nft") {
            if (path.size() == 1) {
                return BAD_REQUEST;
            };
            return _handleNft(path[1]);
        };

        return _handleAssets(request.url);     
    };

    private func _handleAssets(path : Text) : Http.Response {
        Debug.print("Handling asset " # path);
        switch(staticAssets.get(path)) {
            case null {
                if (path == "/index.html") return NOT_FOUND;
                return _handleAssets("/index.html");
            };
            case (?asset) {
                if (asset.payload.size() > 1) {
                    return _handleLargeContent(path, asset.contentType, asset.payload);
                } else {
                    return {
                        body = asset.payload[0];
                        headers = [("Content-Type", asset.contentType)];
                        status_code = 200;
                        streaming_strategy = null;
                    };
                }
            }
        };
    };

    private func _handleNft(id : Text) : Http.Response {
        Debug.print("Here c");
        let nftID = NftTypes.TextToNFTID(id);
        switch(nfts.get(nftID.seq)) {
            case null return NOT_FOUND;
            case (?v) {
                assert(v.amount > nftID.index);
                
                if (v.isPrivate) {return UNAUTHORIZED};
                if (v.payload.size() > 1) {
                    return _handleLargeContent(id, v.contentType, v.payload);
                } else {
                    return {
                        status_code = 200;
                        headers = [("Content-Type", v.contentType)];
                        body = v.payload[0];
                        streaming_strategy = null;
                    };
                };
            };
        };
    };

    private func _handleLargeContent(id : Text, contentType : Text, data : [Blob]) : Http.Response {
        Debug.print("Here b");
        let (payload, token) = _streamContent(id, 0, data);

       switch(token){
            case (?value){
                 return {
                    status_code = 200;
                    headers = [("Content-Type", contentType)];
                    body = payload;
                    streaming_strategy = ? #Callback({

                        token = value;
                        callback = http_request_streaming_callback;
                    });
                };
            };
            case (_){
                return {
                    status_code = 200;
                    headers = [("Content-Type", contentType)];
                    body = payload;
                    streaming_strategy = null;
                };
            };
        };
       
    };

    public query func http_request_streaming_callback(token : Http.StreamingCallbackToken) : async Http.StreamingCallbackResponse {
        let nftID = NftTypes.TextToNFTID(token.key);
        switch(nfts.get(nftID.seq)) {
            case null return {body = Blob.fromArray([]); token = null};
            case (?v) {
                assert(v.amount > nftID.index);

                if (v.isPrivate) {return {body = Blob.fromArray([]); token = null}};
                let res = _streamContent(token.key, token.index, v.payload);
                return {
                    body = res.0;
                    token = res.1;
                }
            }
        }
    };

    private func _streamContent(id : Text, idx : Nat, data : [Blob]) : (Blob, ?Http.StreamingCallbackToken) {
        let payload = data[idx];
        let size = data.size();

        if (idx + 1 == size) {
            return (payload, null);
        };

        return (payload, ?{
            content_encoding = "gzip";
            index = idx + 1;
            sha256 = null;
            key = id;
        });
    };
}