import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import HashMap "mo:base/HashMap";
import Http "http";
import Iter "mo:base/Iter";
import MapHelper "mapHelper";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Types "types";

module Token {

    public let AUTHORIZED_LIMIT = 25;

    public type AuthorizeRequest = {
        id           : Text;
        p            : Principal;
        isAuthorized : Bool;
    };

    public type Token = {
        payload     : [Blob];
        contentType : Text;
        createdAt   : Int;
        properties  : ?Property;
        isPrivate   : Bool;
    };

    public type PublicToken = {
        id          : Text;
        payload     : PayloadResult;
        contentType : Text;
        owner       : Principal;
        createdAt   : Int;
        properties  : ?Property;
    };

    public type PayloadResult = {
        #Complete : Blob;
        #Chunk    : Chunk;
    };

    public type Chunk = {
        data       : Blob; 
        nextPage   : ?Nat; 
        totalPages : Nat;
    };

    public type Property = {
        name      : Text; 
        value     : Value; 
        immutable : Bool;
    };

    public type Value = {
        #Int : Int; 
        #Nat : Nat;
        #Float : Float;
        #Text : Text; 
        #Bool : Bool; 
        #Class : [Property]; 
        #Principal : Principal;
        #Empty;
    }; 

    public type Egg = {
        payload : {
            #Payload : Blob;
            #StagedData;
        };
        contentType : Text;
        owner       : ?Principal;
        properties  : ?Property;
        isPrivate   : Bool;
    };

    public class NTFs(
        lastID        : Nat,
        lastTotalSize : Nat,
        nftEntries : [(
            Text, // Token Identifier.
            (
                ?Principal, // Owner of the token.
                [Principal] // Authorized principals.
            ), 
            Token, // NFT data.
        )],
    ) {
        var id = lastID;
        public func currentID() : Nat { id; };

        var totalSize = lastTotalSize;
        public func payloadSize() : Nat { id; };

        var stagedData = Buffer.Buffer<Blob>(0);

        let nfts = HashMap.HashMap<Text, Token>(
            nftEntries.size(),
            Text.equal,
            Text.hash,
        );
        let authorized = HashMap.HashMap<Text, [Principal]>(
            0,
            Text.equal,
            Text.hash,
        );
        let nftToOwner = HashMap.HashMap<Text, Principal>(
            nftEntries.size(),
            Text.equal,
            Text.hash,
        );
        let ownerToNFT = HashMap.HashMap<Principal, [Text]>(
            nftEntries.size(),
            Principal.equal,
            Principal.hash,
        );
        for ((t, (p, ps), nft) in Iter.fromArray(nftEntries)) {
            nfts.put(t, nft);
            if (ps.size() != 0) {
                authorized.put(t, ps);
            };
            switch (p) {
                case (null) {};
                case (? v)  {
                    nftToOwner.put(t, v);
                    switch (ownerToNFT.get(v)) {
                        case (null) ownerToNFT.put(v, [t]);
                        case (? ts) ownerToNFT.put(v, Array.append(ts, [t]));
                    };
                };
            };
        };

        public func entries() : Iter.Iter<(Text, (?Principal, [Principal]), Token)> {
            return Iter.map<(Text, Token), (Text, (?Principal, [Principal]), Token)>(
                nfts.entries(),
                func((t, n) : (Text, Token)) : (Text, (?Principal, [Principal]), Token) {
                    let ps = switch (authorized.get(t)) {
                        case (null) { []; };
                        case (? v)  { v;  };
                    };
                    switch (nftToOwner.get(t)) {
                        case (null) { return (t, (null, ps), n); };
                        case (? p)  { return (t, (?p,   ps), n); };
                    };
                },
            );
        };

        public func getTotalMinted() : Nat {
            return nfts.size();
        };

        public func writeStaged(data : Types.StagedWrite) : async () {
            switch (data) {
                case (#Init(v)) {
                    stagedData := Buffer.Buffer(v.size);
                    ignore Types.notify(v.callback);
                };
                case (#Chunk(v)) {
                    stagedData.add(v.chunk);
                    ignore Types.notify(v.callback);
                };
            };
        };

        public func ownerOf(id : Text) : Result.Result<Principal, Types.Error> {
            switch (nftToOwner.get(id)) {
                case (null) { return #err(#NotFound); };
                case (? v)  { return #ok(v);          };
            };
        };

        public func isAuthorized(p : Principal, id : Text) : Bool {
            switch (authorized.get(id)) {
                case (null) { false; };
                case (? ps) {
                    // Check wheter the principal is authorized.
                    switch (Array.find<Principal>(ps, func (v) { return v == p; })) {
                        case (null) { false; };
                        case (?  v) { true;  };
                    };
                };
            };
        };

        public func getAuthorized(id : Text) : [Principal] {
            switch (authorized.get(id)) {
                case (null) { return []; };
                case (? v)  { return v;  };
            };
        };

        public func tokensOf(p : Principal) : [Text] {
            switch (ownerToNFT.get(p)) {
                case (null) { return []; };
                case (? v)  { return v;  };
            };
        };

        public func mint(hub : Principal, egg : Egg) : async (Text, Principal) {
            let thisID = Nat.toText(id);
            let size   = switch (egg.payload) {
                case (#Payload(v)) {
                    nfts.put(thisID, {
                        contentType = egg.contentType;
                        createdAt   = Time.now();
                        payload     = [v];
                        properties  = egg.properties;
                        isPrivate   = egg.isPrivate;
                    });
                    v.size();
                };
                case (#StagedData) {
                    nfts.put(thisID, {
                        contentType = egg.contentType;
                        createdAt   = Time.now();
                        payload     = stagedData.toArray();
                        properties  = egg.properties;
                        isPrivate   = egg.isPrivate;
                    });
                    var size = 0;
                    for (x in stagedData.vals()) {
                        size := size + x.size();
                    };
                    stagedData := Buffer.Buffer(0);
                    size;
                };
            };
            id        += 1;
            totalSize += size;

            let owner = switch (egg.owner) {
                case (null) { hub; };
                case (? v)  { v;   };
            };

            nftToOwner.put(thisID, owner);
            MapHelper.add<Principal, Text>(
                ownerToNFT,
                owner,
                thisID,
                MapHelper.textEqual(thisID),
            );

            (thisID, owner);
        };

        public func transfer(to : Principal, id : Text) : async Result.Result<(), Types.Error> {
            switch (nfts.get(id)) {
                case (null) {
                    // NFT does not exist.
                    return #err(#NotFound);
                };
                case (? v) {};
            };
            switch (nftToOwner.get(id)) {
                case (null) { };
                case (? v)  {
                    // Can not send NFT to yourself.
                    if (v == to) { return #err(#InvalidRequest); };
                    // Remove previous owner.
                    MapHelper.filter<Principal, Text>(
                        ownerToNFT, 
                        v, 
                        id, 
                        MapHelper.textNotEqual(id),
                    );
                };
            };
            MapHelper.add<Principal, Text>(
                ownerToNFT, 
                to,
                id, 
                MapHelper.textEqual(id),
            );
            #ok();
        };

        public func authorize(req : AuthorizeRequest) : Bool {
            if (not req.isAuthorized) {
                MapHelper.filter<Text,Principal>(
                    authorized,
                    req.id,
                    req.p,
                    func (v) { v != req.p },
                );
                return true;
            };
            MapHelper.addIfNotLimit<Text, Principal>(
                authorized,
                req.id,
                req.p,
                AUTHORIZED_LIMIT,
                MapHelper.principalEqual(req.p),
            );
        };

        public func getToken(id : Text) : Result.Result<Token, Types.Error> {
            switch (nfts.get(id)) {
                case (null) { return #err(#NotFound); };
                case (? v)  { return #ok(v);          };
            };
        };

        // Limitation: callback is a shared function and is only allowed as a public field of an actor.
        public func get(key : Text, callback : Http.StreamingCallback) : Http.Response {
            switch (nfts.get(key)) {
                case (null) { Http.NOT_FOUND() };
                case (? v)  {
                    if (v.isPrivate) return Http.UNAUTHORIZED();
                    if (v.payload.size() > 1) {
                        return Http.handleLargeContent(
                            key,
                            v.contentType,
                            v.payload,
                            callback,
                        );
                    };
                    return {
                        status_code        = 200;
                        headers            = [("Content-Type", v.contentType)];
                        body               = v.payload[0];
                        streaming_strategy = null;
                    };
                };
            };
        };
    };
};
