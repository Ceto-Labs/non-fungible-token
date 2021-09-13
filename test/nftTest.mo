import nft "../src/nft";
import NftTypes "../src/types";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Result "mo:base/Result";
import Cycles "mo:base/ExperimentalCycles";

actor nftTest {

    //let actorNft : ?actor {} = null;

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
                };
            };
        };

        //Cycles.add(msg.topupAmount);
        await msg.topupCallback();
    };

    public func run() : async (){
        let actorNft = await nft.Nft();

        let self = Principal.fromActor(nftTest);
        await actorNft.init([self], {
            name = "init";
            symbol = "init";
        });

        // set event call back
        await actorNft.setEventCallback(eventCallback);

        // create 
        let payloads :[[Nat8]] = [[1,2,3],[0,0,0],[5,5,5,5]];
        let proper :NftTypes.Property = {name = "first gif"; value=#Int(0); immutable=true};
        let egg : NftTypes.NftEgg = {
            payload = #Payload(payloads);
            contentType = "GIF";
            owner = ?self;
            properties = ?proper;
            isPrivate = false;
        };

        let mintIDs = await actorNft.mint(egg);

        let (totalMinted, totalNfts) = await actorNft.getTotalMinted();

        assert(totalMinted == 1 and totalNfts == payloads.size());
        Debug.print(debug_show("new total nfts:",totalNfts, "IDs:", mintIDs));

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
            Debug.print(debug_show("auths :",auths));
        };

        let authorTo = Principal.fromText("w3c4p-nfokg-flxoh-5agcl-jkhew-t3vlj-xd2j3-ryx7y-mak4p-xlt6g-6ae");
        let authorReq : NftTypes.AuthorizeRequest = {
            id = balances0;
            user = [authorTo, authorTo, authorTo];
            isAuthorized = [true,true,true];
        };
        
        // authorize
        let retAuth = await actorNft.authorize(authorReq);
        switch(retAuth){
            case (#ok()){};
            case (#err(v)){assert(false)};
        };
        for (i in Array.keys<Text>(balances0)){
            let auths = await actorNft.getAuthorized(balances0[i]);
            assert(auths[0] == authorTo);
        };

        // transfer
        let to = Principal.fromText("tz2ss-56jvu-blwni-m5mmc-lj445-rl34w-c7klz-eidog-fc4ak-yoqlt-lae");

        let trsq : NftTypes.TransferRequest = {
            to = [to, to, to];
            id = balances0;
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
        let retNfts = await actorNft.tokensByID("0");
        switch (retNfts){
            case (#ok(nfts)){
                Debug.print(debug_show(nfts));
                assert(nfts.size() == payloads.size());
            };
            case (#err(e)){
                assert(false);
            };
        };


        // burn

        // http

        Debug.print(debug_show("contract info:\n", await actorNft.getContractInfoInsecure()));
        Debug.print("passed !!!")
    };    


    public func txtToNat(num : Text) : async (Nat){
        return NftTypes.textToNat(num);
    };
};