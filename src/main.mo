import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Event "event";
import ExperimentalCycles "mo:base/ExperimentalCycles";
import Http "http";
import Iter "mo:base/Iter";
import MapHelper "mapHelper";
import Prim "mo:⛔";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Static "static";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Token "token";
import Types "types";

shared({ caller = hub }) actor class Hub() = this {
    var MAX_RESULT_SIZE_BYTES     = 1_000_000; // 1MB Default
    var HTTP_STREAMING_SIZE_BYTES = 1_900_000;

    stable var CONTRACT_METADATA : ContractMetadata = {
        name   = "none"; 
        symbol = "none";
    };
    stable var INITALIZED : Bool = false;

    stable var TOPUP_AMOUNT             = 2_000_000;
    stable var BROKER_CALL_LIMIT        = 25;
    stable var BROKER_FAILED_CALL_LIMIT = 25;

    stable var id          = 0;
    stable var payloadSize = 0;
    stable var nftEntries : [(
        Text, // Token Identifier.
        (
            ?Principal, // Owner of the token.
            [Principal] // Authorized principals.
        ),
        Token.Token, // NFT data.
    )] = [];
    let nfts = Token.NTFs(
        id, 
        payloadSize, 
        nftEntries,
    );

    stable var staticAssetsEntries : [(
        Text,        // Asset Identifier (path).
        Static.Asset // Asset data.
    )] = [];
    let staticAssets = Static.Assets(staticAssetsEntries);
    
    stable var contractOwners : [Principal] = [hub];

    stable var messageBrokerCallback : ?Event.Callback = null;
    stable var messageBrokerCallsSinceLastTopup : Nat = 0;
    stable var messageBrokerFailedCalls : Nat = 0;

    public type UpdateEventCallback = {
        #Set : Event.Callback;
        #Remove;
    };

    // Removes or updates the event callback.
    public shared ({caller}) func updateEventCallback(update : UpdateEventCallback) : async () {
        assert(_isOwner(caller));
        // TODO: reset 'failed calls/calls since last topup'?
        switch (update) {
            case (#Remove) {
                messageBrokerCallback := null;  
            };
            case (#Set(cb)) {
                messageBrokerCallback := ?cb;
            };
        };
    };

    // Returns the event callback status.
    public shared ({caller}) func getEventCallbackStatus() : async Event.CallbackStatus {
        assert(_isOwner(caller));
        return {
            callback            = messageBrokerCallback;
            callsSinceLastTopup = messageBrokerCallsSinceLastTopup;
            failedCalls         = messageBrokerFailedCalls;
            noTopupCallLimit    = BROKER_CALL_LIMIT;
            failedCallsLimit    = BROKER_FAILED_CALL_LIMIT;
        };
    };

    system func preupgrade() {
        id                  := nfts.currentID();
        payloadSize         := nfts.payloadSize();
        nftEntries          := Iter.toArray(nfts.entries());
        staticAssetsEntries := Iter.toArray(staticAssets.entries());
    };

    system func postupgrade() {
        id                  := 0;
        payloadSize         := 0;
        nftEntries          := [];
        staticAssetsEntries := [];
    };

    // Initializes the contract with the given (additional) owners and metadata. Can only be called once.
    // @pre: isOwner
    public shared({caller}) func init(
        owners   : [Principal],
        metadata : ContractMetadata,
    ) : async () {
        assert(not INITALIZED and caller == hub);
        contractOwners    := Array.append(contractOwners, owners);
        CONTRACT_METADATA := metadata;
        INITALIZED        := true;
    };

    // Updates the access rights of one of the contact owners.
    public shared({caller}) func updateContractOwners(
        user          : Principal, 
        isAuthorized : Bool,
    ) : async Result.Result<(), Types.Error> {
        if (not _isOwner(caller)) { return #err(#Unauthorized); };

        switch(isAuthorized) {
            case (true) {
                contractOwners := Array.append(
                    contractOwners,
                    [user],
                );
            };
            case (false) {
                contractOwners := Array.filter<Principal>(
                    contractOwners, 
                    func(v) { v != user; },
                );
            };
        };
        ignore _emitEvent({
            createdAt     = Time.now();
            event         = #ContractEvent(
                #ContractAuthorize({
                    user         = user;
                    isAuthorized = isAuthorized;
                }),
            );
            topupAmount   = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
        #ok();
    };

    public type ContractMetadata = {
        name   : Text;
        symbol : Text;
    };

    // Returns the meta data of the contract.
    public query func getMetadata() : async ContractMetadata {
        CONTRACT_METADATA;
    };

    // Returns the total amount of minted NFTs.
    public query func getTotalMinted() : async Nat {
        nfts.getTotalMinted();
    };

    public shared({caller}) func wallet_receive() : async () {
        ignore ExperimentalCycles.accept(ExperimentalCycles.available());
    };

    // Mints a new egg.
    // @pre: isOwner
    public shared ({caller}) func mint(egg : Token.Egg) : async Text {
        assert(_isOwner(caller));
        let (id, owner) = await nfts.mint(Principal.fromActor(this), egg);
        ignore _emitEvent({
            createdAt     = Time.now();
            event         = #ContractEvent(
                #Mint({
                    id    = id; 
                    owner = owner;
                }),
            );
            topupAmount   = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
        id;
    };

    // Writes a part of an NFT to the staged data. 
    // Initializing another NFT will destruct the data in the buffer.
    public shared({caller}) func writeStaged(data : Types.StagedWrite) : async () {
        assert(_isOwner(caller));
        await nfts.writeStaged(data);
    };

    public type ContractInfo = {
        heap_size : Nat; 
        memory_size : Nat;
        max_live_size : Nat;
        nft_payload_size : Nat; 
        total_minted : Nat; 
        cycles : Nat; 
        authorized_users : [Principal]
    };

    // Returns the contract info.
    // @pre: isOwner
    public shared ({caller}) func getContractInfo() : async ContractInfo {
        assert(_isOwner(caller));
        return {
            heap_size        = Prim.rts_heap_size();
            memory_size      = Prim.rts_memory_size();
            max_live_size    = Prim.rts_max_live_size();
            nft_payload_size = payloadSize; 
            total_minted     = nfts.getTotalMinted(); 
            cycles           = ExperimentalCycles.balance();
            authorized_users = contractOwners;
        };
    };

    // List all static assets.
    // @pre: isOwner
    public query ({caller}) func listAssets() : async [(Text, Text, Nat)] {
        assert(_isOwner(caller));
        staticAssets.list();
    };

    // Allows you to replace delete and stage NFTs.
    // Putting and initializing staged data will overwrite the present data.
    public shared ({caller}) func assetRequest(data : Static.AssetRequest) : async (){
        assert(_isOwner(caller));
        await staticAssets.handleRequest(data);
    };

    // Returns the tokens of the given principal.
    public query func balanceOf(p : Principal) : async [Text] {
        nfts.tokensOf(p);
    };

    // Returns the owner of the NFT with given identifier.
    public query func ownerOf(id : Text) : async Result.Result<Principal, Types.Error> {
        nfts.ownerOf(id);
    };

    // Transfers one of your own NFTs to another principal.
    public shared ({caller}) func transfer(to : Principal, id : Text) : async Result.Result<(), Types.Error> {
        let owner = switch (_canChange(caller, id)) {
            case (#err(e)) { return #err(e); };
            case (#ok(v))  { v; };
        };
        let res = await nfts.transfer(to, id);
        ignore _emitEvent({
            createdAt     = Time.now();
            event         = #TokenEvent(
                #Transfer({
                    from = owner; 
                    to   = to; 
                    id   = id;
                }));
            topupAmount   = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
        res;
    };

    // Allows the caller to authorize another principal to act on its behalf.
    public shared ({caller}) func authorize(req : Token.AuthorizeRequest) : async Result.Result<(), Types.Error> {
        switch (_canChange(caller, req.id)) {
            case (#err(e)) { return #err(e); };
            case (#ok(v))  { };
        };
        if (not nfts.authorize(req)) {
            return #err(#AuthorizedPrincipalLimitReached(Token.AUTHORIZED_LIMIT))
        };
        ignore _emitEvent({
            createdAt     = Time.now();
            event         = #TokenEvent(
                #Authorize({
                    id           = req.id; 
                    user         = req.p; 
                    isAuthorized = req.isAuthorized;
                }));
            topupAmount   = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
        #ok();
    };

    private func _canChange(caller : Principal, id : Text) : Result.Result<Principal, Types.Error> {
        let owner = switch (nfts.ownerOf(id)) {
            case (#err(e)) {
                if (not _isOwner(caller)) return #err(e);
                Principal.fromActor(this);
            };
            case (#ok(v))  {
                // The owner not is the caller.
                if (not _isOwner(caller) and v != caller) {
                    // Check whether the caller is authorized.
                    if (not nfts.isAuthorized(caller, id)) return #err(#Unauthorized);
                };
                v;
            };
        };
        #ok(owner);
    };

    // Returns whether the given principal is authorized to change to NFT with the given identifier.
    public query func isAuthorized(id : Text, p : Principal) : async Bool {
        nfts.isAuthorized(p, id);
    };

    // Returns which principals are authorized to change the NFT with the given identifier.
    public query func getAuthorized(id : Text) : async [Principal] {
        nfts.getAuthorized(id);
    };

    // Gets the token with the given identifier.
    public shared({caller}) func tokenByIndex(id : Text) : async Result.Result<Token.PublicToken, Types.Error> {
        switch(nfts.getToken(id)) {
            case (#err(e)) { return #err(e); };
            case (#ok(v)) {
                if (v.isPrivate) {
                    if (not nfts.isAuthorized(caller, id) and not _isOwner(caller)) {
                        return #err(#Unauthorized);
                    };
                };
                var payloadResult : Token.PayloadResult = #Complete(v.payload[0]);
                if (v.payload.size() > 1) {
                    payloadResult := #Chunk({
                        data       = v.payload[0]; 
                        totalPages = v.payload.size(); 
                        nextPage   = ?1;
                    });
                };
                let owner = switch (nfts.ownerOf(id)) {
                    case (#err(_)) { Principal.fromActor(this); };
                    case (#ok(v))  { v;                         }; 
                };
                return #ok({
                    contentType = v.contentType;
                    createdAt = v.createdAt;
                    id = id;
                    owner = owner;
                    payload = payloadResult;
                    properties = v.properties;
                });
            }
        }
    };
    
    // Gets the token chuck with the given identifier and page number.
    public shared ({caller}) func tokenChunkByIndex(id : Text, page : Nat) : async Result.Result<Token.Chunk, Types.Error> {
        switch (nfts.getToken(id)) {
            case (#err(e)) { return #err(e); };
            case (#ok(v)) {
                if (v.isPrivate) {
                    if (not nfts.isAuthorized(caller, id) and not _isOwner(caller)) {
                        return #err(#Unauthorized);
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
                    data       = v.payload[page];
                    nextPage   = nextPage;
                    totalPages = totalPages;
                });
            };
        };
    };

    private func _isOwner(p : Principal) : Bool {
        switch(Array.find<Principal>(contractOwners, func(v) {return v == p})) {
            case (null) { false; };
            case (? v)  { true;  };
        };
    };

    private func _emitEvent(event : Event.Message) : async () {
        let emit = func(broker : Event.Callback, msg : Event.Message) : async () {
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
            case (null)    { return; };
            case (?broker) {
                if (messageBrokerCallsSinceLastTopup > BROKER_CALL_LIMIT) return;
                ignore emit(broker, event);
            };
        };
    };

    // HTTP interface

    public query func http_request(request : Http.Request) : async Http.Response {
        let path = Iter.toArray(Text.tokens(request.url, #text("/")));
        if (path.size() != 0 and path[0] == "nft") {
            if (path.size() != 2) {
                return Http.BAD_REQUEST();
            };
            return nfts.get(path[1], nftStreamingCallback);
        };
        return staticAssets.get(request.url, staticStreamingCallback);
    };

    // A streaming callback based on static assets.
    // Returns {[], null} if the asset can not be found.
    public query func staticStreamingCallback(tk : Http.StreamingCallbackToken) : async Http.StreamingCallbackResponse {
        switch(staticAssets.getToken(tk.key)) {
            case null return {
                body = Blob.fromArray([]);
                token = null;
            };
            case (? v) {
                let (body, token) = Http.streamContent(
                    tk.key,
                    tk.index,
                    v.payload,
                );
                return {
                    body = body;
                    token = token;
                };
            };
        };
    };

    // A streaming callback based on NFTs.
    // Returns {[], null} if the token can not be found.
    public query func nftStreamingCallback(tk : Http.StreamingCallbackToken) : async Http.StreamingCallbackResponse {
        switch(nfts.getToken(tk.key)) {
            case (#err(e)) {};
            case (#ok(v)) {
                if (not v.isPrivate) {
                    let (body, token) = Http.streamContent(
                        tk.key,
                        tk.index,
                        v.payload,
                    );
                    return {
                        body  = body;
                        token = token;
                    };
                };
            };
        };
        {
            body  = Blob.fromArray([]);
            token = null;
        };
    };

    public query func http_request_streaming_callback(
        token : Http.StreamingCallbackToken
    ) : async Http.StreamingCallbackResponse {
        switch(nfts.getToken(token.key)) {
            case (#err(_)) {
                // TODO: also check static assets?
                {
                    body  = Blob.fromArray([]); 
                    token = null;
                };
            };
            case (#ok(v)) {
                let (payload, cbt) = Http.streamContent(
                    token.key, 
                    token.index, 
                    v.payload,
                );
                {
                    body  = payload;
                    token = cbt;
                };
            }
        }
    };
};
