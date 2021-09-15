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

actor nftTest {

    public shared(msg) func eventCallback(msg : NftTypes.EventMessage): async (){
        switch(msg.event){
            case (#ContractEvent(cEvent)){
                switch(cEvent){
                    case (#ContractAuthorize(v)){
                        Debug.print(debug_show("ContractAuthorize event", msg.createdAt, msg.topupAmount, "v:", v.isAuthorized, v.user));
                    };
                    case (#Mint(v)){
                        Debug.print(debug_show("Mint event", msg.createdAt, msg.topupAmount, "v:", v.id, v.owner));
                    };
                };
            };
            case (#NftEvent(nEvent)){                
                switch(nEvent){
                    case (#Transfer(v)){
                        Debug.print(debug_show("Transfer event", msg.createdAt, msg.topupAmount, "v:", v.from, v.id, v.to));
                    };
                    case (#Authorize(v)){
                        Debug.print(debug_show("Authorize event", msg.createdAt, msg.topupAmount, "v:", v.id, v.isAuthorized, v.user));
                    };
                    case (#Burn(v)){
                        Debug.print(debug_show("Burn event", msg.createdAt, msg.topupAmount, "v:", v.id, v.owner));
                    };
                };
            };
        };

        //Cycles.add(msg.topupAmount);
        await msg.topupCallback();
    };

    public func run() : async (){
        let actorNft = await nft.Nft();
        Debug.print(debug_show("nft id:",  Principal.fromActor(actorNft)));

        let self = Principal.fromActor(nftTest);
        await actorNft.init([self], {
            name = "init";
            symbol = "init";
        });

        // set event call back
        await actorNft.setEventCallback(eventCallback);

        // create  helloworld
        let payload :[Nat8] = [0x68,0x65,0x6c,0x6c,0x6f,0x20,0x77,0x6f,0x72,0x6c,0x64];
        let proper :NftTypes.Property = {name = "text"; value=#Int(0); immutable=true};
        let egg : NftTypes.NftEgg = {
            payload = #Payload(payload);
            contentType = "txt text/plain";
            owner = ?self;
            properties = ?proper;
            isPrivate = false;
            amount = 10;
        };

        let mintIDs = await actorNft.mint(egg);

        let (totalMinted, totalNfts) = await actorNft.getTotalMinted();

        assert(totalMinted == 1 and totalNfts == Nat32.toNat(egg.amount));

        let balances0 = await actorNft.balanceOf(self);
        for (i in Array.keys<Text>(balances0)){
            let retOwner = await actorNft.ownerOf(balances0[i]);
            switch (retOwner){
                case (#ok(owner)){
                    assert(owner==self);
                };
                case (#err(e)){
                    Debug.print(debug_show("owner of ret err:", e));
                    assert(false);
                };
            };

            assert(mintIDs[i] == balances0[i]);
            let auths = await actorNft.getAuthorized(balances0[i]);
            assert(auths == []);
        };

        let authorTo = Principal.fromText("w3c4p-nfokg-flxoh-5agcl-jkhew-t3vlj-xd2j3-ryx7y-mak4p-xlt6g-6ae");
        let authorReq : NftTypes.AuthorizeRequest = {
            id = [balances0[0], balances0[1],balances0[2]];
            user = [authorTo, authorTo, authorTo];
            isAuthorized = [true,true,true];
        };
        
        // authorize
        let retAuth = await actorNft.authorize(authorReq);
        switch(retAuth){
            case (#ok()){};
            case (#err(v)){assert(false)};
        };

        for (i in Array.keys<Text>(authorReq.id)){
            let auths = await actorNft.getAuthorized(balances0[i]);
            assert(auths[0] == authorTo);
        };

        // transfer
        let to = Principal.fromText("tz2ss-56jvu-blwni-m5mmc-lj445-rl34w-c7klz-eidog-fc4ak-yoqlt-lae");

        let trsq : NftTypes.TransferRequest = {
            to = [to, to];
            id = [balances0[0], balances0[1]];
        };
        let trsRet = await actorNft.transfer(trsq);
        switch(trsRet){
            case (#ok()){};
            case (#err(e))(assert(false));
        };

        let balances1 = await actorNft.balanceOf(to);
        for (i in Array.keys<Text>(balances1)){
            let retOwner = await actorNft.ownerOf(balances1[i]);
            switch (retOwner){
                case (#ok(owner)){
                    assert(owner==to);
                };
                case (#err(e)){
                    Debug.print(debug_show("owner of ret err:", e));
                    assert(false);
                };
            };

            assert(balances0[i] == balances1[i]);

            let auths = await actorNft.getAuthorized(balances1[i]);
            assert(auths.size() == 0);

            let ownerRet = await actorNft.ownerOf(balances1[i]);
            switch (ownerRet){
                case (#ok(owner)){
                    assert(owner == to);
                };
                case (#err(v)){assert(false)};
            };  
        };

        // query
        switch (await actorNft.tokenByID("0")){
            case (#ok(nfts)){
                assert(false);
            };
            case (#err(e)){
                //Debug.print(debug_show("test  incomplete id", e));
            };
        };

        do{
            switch (await actorNft.tokenByID(balances0[0])){
                case (#ok(nft)){                    
                    let retPayload = switch(nft.payload){
                        case (#Complete(v)){v;};
                        case (#Chunk(v)){
                            // to do check all data
                            v.data;
                        };
                    };
                    
                    assert(Array.equal<Nat8>(payload, Blob.toArray(retPayload), func(a : Nat8, b : Nat8): Bool{
                        return Nat8.equal(a, b);
                    }));
                    
                };
                case (#err(e)){
                    assert(false);
                };
            };
        };

        // Properties

     
        // burn
        do {
            let retBurn = await actorNft.burn(balances0[2]);
            switch(retBurn){
                case (#ok){};
                case (#err(v)){
                    assert(false);
                };
            };
        };

        do{
            try{
                let retBurn = await actorNft.burn(balances0[0]);
                switch(retBurn){
                    case (#ok){ assert(false);};
                    case (#err(v)){ };
                };
            } catch (e){
                //Debug.print(debug_show("should burn exception", Error.message(e)));
            };
        };

        do{
            let (totalMinted, totalNfts) = await actorNft.getTotalMinted();
            assert(totalMinted == 1 and totalNfts == Nat32.toNat(egg.amount-1));
            let leftNft = await actorNft.balanceOf(self);
            assert(Nat32.toNat(egg.amount) == Nat.add(leftNft.size(), 1) + trsq.to.size());
        };

        // http

        Debug.print(debug_show("contract info:\n", await actorNft.getContractInfo()));
        Debug.print("passed !!!")
    };    


    public func txtToNat(num : Text) : async (Nat){
        return NftTypes.textToNat(num);
    };
};