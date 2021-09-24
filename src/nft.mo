import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Cycles "mo:base/ExperimentalCycles";
import Hash "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Otn "ownerToNft";
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
import Auth "authrized";

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

    //An NFT may correspond to multiple owners
    stable var nftToOwnerEntries : [(Text, [Principal])] = [];
    let nftToOwner = HashMap.fromIter<Text, [Principal]>(nftToOwnerEntries.vals(), 15, Text.equal, Text.hash);

    stable var ownerToNftEntries : [(Principal, [(Text, Nat)])] = [];
    let ownerToNft = HashMap.HashMap<Principal, HashMap.HashMap<Text, Nat>>(15, Principal.equal, Principal.hash);

    //key : owner, value: (opertor, token)
    stable var authorizedEntries : [(Principal,[(Principal, [NftTypes.Token])])] = [];
    let authorized = HashMap.HashMap<Principal,  HashMap.HashMap<Principal, [NftTypes.Token]>>(15, Principal.equal, Principal.hash);
    
    stable var contractOwners : [Principal] = [hub];
    
    stable var messageBrokerCallback : ?NftTypes.EventCallback = null;
    stable var messageBrokerCallsSinceLastTopup : Nat = 0;
    stable var messageBrokerFailedCalls : Nat = 0;

    var stagedNftData = HashMap.HashMap<Principal , Buffer.Buffer<Blob>>(1, Principal.equal, Principal.hash);
    var stagedAssetData = Buffer.Buffer<Blob>(0);
    
    //--------------------------------------------------------func-------------------------------------------------------
    system func preupgrade() {
        nftEntries := Iter.toArray(nfts.entries());
        staticAssetsEntries := Iter.toArray(staticAssets.entries());
        nftToOwnerEntries := Iter.toArray(nftToOwner.entries());

        var size : Nat = ownerToNft.size();
        var temp : [var (Principal, [(Text, Nat)])] = Array.init<(Principal, [(Text, Nat)])>(size, (hub, []));
        size := 0;
        for ((k, v) in ownerToNft.entries()) {
            temp[size] := (k, Iter.toArray(v.entries()));
            size += 1;
        };
        ownerToNftEntries := Array.freeze(temp);

        size := authorized.size();
        var tmpAuthorized : [var (Principal,[(Principal, [NftTypes.Token])])] = Array.init<(Principal,[(Principal, [NftTypes.Token])])>(size,(hub,[]));
        size := 0;
        for ((k, v) in authorized.entries()) {
            tmpAuthorized[size] := (k, Iter.toArray(v.entries()));
            size += 1;
        };
        authorizedEntries := Array.freeze(tmpAuthorized);
    };

    system func postupgrade() {   
        for ((k, v) in ownerToNftEntries.vals()) {
            let temp = HashMap.fromIter<Text, Nat>(v.vals(), 1, Text.equal, Text.hash);
            ownerToNft.put(k, temp);
        };

        for ((k, v) in authorizedEntries.vals()) {
            let temp = HashMap.fromIter<Principal, [NftTypes.Token]>(v.vals(), 1, Principal.equal, Principal.hash);
            authorized.put(k, temp);
        };
       
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
            totalSize  += v.amount;
        };
        return (nfts.size(), totalSize);
    };

    public shared ({caller = caller}) func mint(egg : NftTypes.NftEgg) : async Text {
        return await _mint(caller, egg)
    };

    public shared({caller = caller}) func burn(id : Text, amount : Nat) : async (NftTypes.BurnResult){
        return await _burn(caller, id, amount);
    };

    public func balanceOf(p : Principal, id : Text) : async Nat {
        return Otn.balanceOf(ownerToNft,p,id);
    };

    public shared ({caller = caller}) func transferFrom(transferRequest : NftTypes.TransferRequest) : async NftTypes.TransferResult {
        return await _transferFrom(caller, transferRequest);
    };

    public shared ({caller = caller}) func authorize(authorizeRequest : NftTypes.AuthorizeRequest) : async NftTypes.AuthorizeResult {
        return await _authorize(caller, authorizeRequest);
    };

    public shared({caller = caller}) func tokenByID(id : Text) : async NftTypes.NftResult {

        switch(nfts.get(id)) {
            case null return #err(#NotFound);
            case (?v) {
                if (v.isPrivate) {
                    switch(_isAuthorized(caller, caller, id)) {
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
                    owners = _ownerOf(id);
                    payload = payloadResult;
                    properties = v.properties;
                    amount = v.amount;
                });    
            };                         
        };
    };
 
    public shared({caller = caller}) func isAuthorized(id : Text, user : Principal) : async Bool {
        switch (_isAuthorized(caller, user, id)) {
            case (#ok()) return true;
            case (_) return false;
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

    public shared func getAuthorized(owner : Principal, id : Text) : async [NftTypes.AuthorizeInfo] {
        return Auth.getAuthorized(authorized, owner, id);
    };
    
    public shared ({caller = caller}) func tokenChunkByID(id : Text, page : Nat) : async NftTypes.ChunkResult {

        switch (nfts.get(id)) {
            case null return #err(#NotFound);
            case (?v) {
                if (v.isPrivate) {
                    switch(_isAuthorized(caller, caller, id)) {
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

    public query ({caller = caller}) func queryProperties(propertyQuery : NftTypes.PropertyQueryRequest) : async NftTypes.PropertyQueryResult {
 
        switch(propertyQuery.mode) {
            case (#All) {
                switch(nfts.get(propertyQuery.id)) {
                    case (null) {return #err(#NotFound)};
                    case (?v) {                        

                        if (v.isPrivate) {
                            switch(_isAuthorized(caller, caller, propertyQuery.id)) {
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
                return  _handleQueries(caller, propertyQuery.id, v);
            };
        };
    };

    private func _handleQueries(caller : Principal, id : Text, query0 : NftTypes.PropertyQuery) : NftTypes.PropertyQueryResult {

        switch(nfts.get(id)) {
            case (null) return #err(#NotFound);
            case (?v) {
            
                if (v.isPrivate) {
                    switch(_isAuthorized(caller, caller, id)) {
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
        messageBrokerCallsSinceLastTopup := 0;

        ignore Cycles.accept(Cycles.available());
    };

    public shared ({caller = caller})func cycle() : async Nat{
        assert(caller == hub);
        Cycles.balance();
    };

    // Internal Functions

    // mint a new Token, the amount of tokens may be one or more
    private func _mint(caller : Principal, egg : NftTypes.NftEgg) : async Text {
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
        let token : NftTypes.Token = {
            id = thisId;
            amount = egg.amount;
        };
        assert(Otn.add(ownerToNft, owner, token));
        nftToOwner.put(thisId, [owner]);
    
        ignore _emitEvent({
            createdAt = Time.now();
            event = #ContractEvent(#Mint({id = thisId; owner = owner}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
        return thisId;
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

    private func _ownerOf(id : Text) : [Principal] {
        switch(nftToOwner.get(id)) {
            case (null) return [Principal.fromActor(this)];
            case (?vs) return vs;
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
    private func _transferFrom(caller : Principal, transferRequest : NftTypes.TransferRequest) : async NftTypes.TransferResult {
        assert(transferRequest.amount.size() == transferRequest.id.size());
        assert(transferRequest.from != transferRequest.to);
        var self = Principal.fromActor(this);

        for (key in Array.keys<Text>(transferRequest.id)){
            let id = transferRequest.id[key];
            let amount = transferRequest.amount[key];
            switch(nfts.get(id)) {
                case null {
                    // todo add to log
                    assert(false)
                };
                case (?v) {}; // Nft Exists
            };

            switch (nftToOwner.get(id)) {             
                case null { assert(false) };
                case (?owners) {
                    var found = false;
                    var i = 0;
                    while ( i < owners.size() and not found ){
                        if (owners[i] == transferRequest.from){
                            found := true;
                        };
                        i += 1;
                    };

                    assert(found);
                };
            };

            let isOwnedContractAndCallerOwner = transferRequest.from == self and _isOwner(caller);
            if (caller != transferRequest.from and not isOwnedContractAndCallerOwner) {
                assert(Auth.isAuthorized(authorized, caller, transferRequest.from, id, amount));
            };

            // Add the transfered NFT to the NTFs of the recipient.
            let token : NftTypes.Token = {id=id; amount=amount};
            
            assert(Otn.add(ownerToNft, transferRequest.to, token));
            // Remove the transfered NFT from the previous NTF owner.
            let moveAll = Otn.sub(ownerToNft, transferRequest.from, token);

            switch(nftToOwner.get(id)){
                case (?owners){
                    var newOwners : [Principal] = [];
                    var removedFrom = false;
                    if (moveAll){
                        newOwners := Array.filter<Principal>(owners, func(v){return v != transferRequest.from});
                        removedFrom := true;
                    } else {
                        newOwners := Array.append<Principal>(newOwners, owners);
                    };

                    switch( Array.find<Principal>(newOwners, func(v){return v == transferRequest.to})) {
                        case (null) {nftToOwner.put(id, Array.append<Principal>(newOwners,[transferRequest.to]))};
                        case (?vs) {if(removedFrom) {nftToOwner.put(id, newOwners)}};
                    };                
                };
                case (null){
                    nftToOwner.put(id, [transferRequest.to]);
                };
            };
            
            assert(Auth.removeAuthorized(authorized, caller, transferRequest.from,id));

            ignore _emitEvent({
                createdAt = Time.now();
                event = #NftEvent(#Transfer({from = transferRequest.from; to = transferRequest.to; id = id; amount = amount}));
                topupAmount = TOPUP_AMOUNT;
                topupCallback = wallet_receive;
            });
        };
               
        return #ok();
    };

    private func _authorize(caller : Principal, r : NftTypes.AuthorizeRequest) : async NftTypes.AuthorizeResult {
        switch(_isAuthorized(caller, r.user, r.id)) {
            case (#err(v)) { //todo err to log 
                assert(false);
            };
            case (_) {} // Ok;
        };

        Auth.updateAuthorized(authorized, caller, r);

        ignore _emitEvent({
            createdAt = Time.now();
            event = #NftEvent(#Authorize({id = r.id; owner = caller; user = r.user; amount = r.amount}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
    
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

    private func _isAuthorized(caller : Principal, user : Principal, id : Text) : Result.Result<(), NftTypes.Error> {
        switch (nfts.get(id)) {
            case null return #err(#NotFound);
            case _ {};
        };
        
        switch (nftToOwner.get(id)) {
            case null {}; // Not owner. Check if authd
            case (?owners) {
                switch(Array.find<Principal>(owners, func(v){caller == v})){
                    case null {};
                    case (?v){ return #ok(); };
                };

                switch(Array.find<Principal>(owners, func(v){ Principal.fromActor(this) == v})){
                    case null {};
                    case (?v){ // Owner is contract
                        if (_isOwner(caller)) {
                            return #ok();
                        };
                    };
                };
            };
        };

        if (Auth.isAuthorized(authorized, caller, user,id, 0)){
            return #ok();
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

    private func _burn(caller : Principal, id : Text, amount : Nat) : async (NftTypes.BurnResult){
        assert(amount > 0);
       
        let burnAll = Otn.burn(ownerToNft, caller, id, amount);

        if (burnAll){
            switch(nftToOwner.get(id)) {
                case (null) {assert(false)};
                case (?owners) {
                    let subOwners = Array.filter<Principal>(owners, func(v){v != caller});
                    if (subOwners.size() > 0){
                        nftToOwner.put(id, subOwners);
                    }else {
                        nftToOwner.delete(id);
                    };
                };
            };
        };

        switch(nfts.get(id)) {
            case (null) {assert(false)};
            case (?v) {                        
                var newV : NftTypes.Nft = {
                    payload = v.payload;
                    contentType = v.contentType;
                    createdAt = v.createdAt;
                    properties = v.properties;
                    isPrivate = v.isPrivate;
                    amount = v.amount - amount;
                };
                
                if (newV.amount > 0){
                    nfts.put(id, newV);
                } else {
                    nfts.delete(id);
                };
            };
        };

        ignore _emitEvent({
            createdAt = Time.now();
            event = #NftEvent(#Burn({owner = caller;id = id; amount = amount}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });

        return #ok();
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
        switch(nfts.get(id)) {
            case null return NOT_FOUND;
            case (?v) {                
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
        switch(nfts.get(token.key)) {
            case null return {body = Blob.fromArray([]); token = null};
            case (?v) {
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