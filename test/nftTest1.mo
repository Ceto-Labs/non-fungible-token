import nft "../src/nft";
import NftTypes "../src/types";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Result "mo:base/Result";
import Cycles "mo:base/ExperimentalCycles";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat "mo:base/Nat";
import Error "mo:base/Error";
import Nat32 "mo:base/Nat32";


actor class nftTest1() = this {
    public func test(nftActor : Principal, amount : Nat, payload : [Nat8], user : Principal) : async (Text){

        let self = Principal.fromActor(this);
        //let self = Principal.fromActor(nftTest);

        let actorNft = actor(Principal.toText(nftActor)) : nft.Nft; 
        // create  helloworld
        let proper :NftTypes.Property = {name = "text"; value=#Int(0); immutable=true};
        let egg : NftTypes.NftEgg = {
            payload = #Payload(payload);
            contentType = "txt text/plain";
            owner = ?self;
            properties = ?proper;
            isPrivate = false;
            amount = amount;
        };

        let mintID = await actorNft.mint(egg);

        let (totalMinted, totalNfts) = await actorNft.getTotalMinted();
        assert(totalMinted == 1 and totalNfts == egg.amount);

        let balance = await actorNft.balanceOf(self, mintID);
        assert(egg.amount == balance);
        
        do {
            let auths = await actorNft.getAuthorized(self, mintID);
            assert(auths == []);
        };

        // authorize
        let authorReq : NftTypes.AuthorizeRequest = {
            id = mintID;
            user = user;
            amount =  amount/3;
        };
        
        let retAuth = await actorNft.authorize(authorReq);
        switch(retAuth){
            case (#ok()){};
            case (#err(v)){assert(false)};
        };
        
        do {
            // An NFT can be authorized to many agents
            let auths = await actorNft.getAuthorized(self, mintID);
            assert(auths[0].id == mintID );
        };

        return mintID;
    };
}