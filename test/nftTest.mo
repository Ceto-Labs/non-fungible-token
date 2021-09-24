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
import NftTest1 "nftTest1";
import NftTest2 "nftTest2";


actor nftTest {
    var burnAmount : Nat = 0;

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
                        Debug.print(debug_show("Transfer event", msg.createdAt, msg.topupAmount, "v:", v.from, v.id, v.to, v.amount));
                    };
                    case (#Authorize(v)){
                        Debug.print(debug_show("Authorize event", msg.createdAt, msg.topupAmount, "v:", v.id, v.amount,"user",v.user, "owner",v.owner));
                    };
                    case (#Burn(v)){
                        burnAmount += v.amount;
                        Debug.print(debug_show("Burn event", msg.createdAt, msg.topupAmount, "v:", v.id, v.owner,v.amount));
                    };
                };
            };
        };

        //Cycles.add(msg.topupAmount);
       ignore msg.topupCallback();
    };

    public func run() : async (){
        let payload :[Nat8] = [0x68,0x65,0x6c,0x6c,0x6f,0x20,0x77,0x6f,0x72,0x6c,0x64];
        let actorNft = await nft.Nft();
        Debug.print(debug_show("nft id:",  Principal.fromActor(actorNft)));

        let self = Principal.fromActor(nftTest);
        await actorNft.init([self], {
            name = "init";
            symbol = "init";
        });

        let amount = 10;
        // set event call back
        await actorNft.setEventCallback(eventCallback);

        let nftTest1 = await NftTest1.nftTest1();
        let nftTest2 = await NftTest2.nftTest2();

        Debug.print(debug_show("nftTest1:", Principal.fromActor(nftTest1)));
        Debug.print(debug_show("nftTest2:", Principal.fromActor(nftTest2)));
        
        let mintID = await nftTest1.test(Principal.fromActor(actorNft), amount, payload, Principal.fromActor(nftTest2));
        let burnNum = await nftTest2.test(Principal.fromActor(actorNft), amount, mintID, payload, Principal.fromActor(nftTest1));

        Debug.print(debug_show("contract info:\n", await actorNft.getContractInfo()));
            
        let leftBalance = await actorNft.balanceOf(Principal.fromActor(nftTest1), mintID);
        let toBalance = await actorNft.balanceOf(Principal.fromActor(nftTest2), mintID);
        Debug.print(debug_show(leftBalance, toBalance, burnAmount));
        assert(amount == leftBalance + burnNum + toBalance);
        Debug.print("passed !!!")
    };
};