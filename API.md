# Public API of the Hub Actor

## Table of Contents

- [Public Methods](#public-api)
  - [Sending Cycles](#sending-cycles)
- [Admin Methods](#private-api)
- [Http Request](#http-request)
  - [Streaming Strategy](#streaming-strategy)

## Public API

- getMetadata() : ContractMetadata
- getTotalMinted() : Nat
- balanceOf(p : Principal) : [Text]
- ownerOf(id : Text) : async Result.Result<Principal, Error>
- isAuthorized(id : Text, p : Principal) : Bool
- getAuthorized(id : Text) : [Principal]

---

```motoko
query getMetadata() : ContractMetadata 
```

Returns the metadata set by the owner of the hub.
Default value: `{name = "none"; symbol = "none"}`.

---

```motoko
query getTotalMinted() : Nat
```

Returns the total amount of minted NFTs (does not include assets).

---

```motoko
balanceOf(p : Principal) : [Text]
```

Returns the tokens of the given principal.

---

```motoko
ownerOf(id : Text) : async Result.Result<Principal, Error>
```

Returns the owner of the NFT with given identifier.

---

```motoko
isAuthorized(id : Text, p : Principal) : Bool
```

Returns whether the given principal is authorized to change to NFT with the given identifier.

---

```motoko
getAuthorized(id : Text) : [Principal]
```

Returns which principals are authorized to change the NFT with the given identifier.

### Sending Cycles

```motoko
wallet_receive()
```

| **TODO**

## Private API

- init(owners : [Principal], metadata : ContractMetadata)
- updateContractOwners(user : Principal, isAuthorized : Bool) : Result.Result<(), Error>
- setEventCallback(cb : EventCallback)
- getContractInfo() : ContractInfo
- mint(egg : NftEgg) : Text
- transfer(transferRequest : TransferRequest) : Result.Result<(), Error>
- writeStaged(data : StagedWrite)
- assetRequest(data : AssetRequest)
- listAssets() : [(Text, Text, Nat)]
- tokenByIndex(id : Text) : Result.Result<PublicNft, Error>

```motoko
init(owners : [Principal], metadata : ContractMetadata)
```

Initializes the hub, and can only be called once.
Sets the metadata and appends the given owners to the current contract owner(s).

---

```motoko
func updateContractOwners(user : Principal, isAuthorized : Bool) : Result.Result<(), Error>
```

Updates the access rights of one of the contact owners.

---

```motoko
updateEventCallback(update : UpdateEventCallback)
```

Removes or updates the event callback.

---

```motoko
getEventCallbackStatus() : EventCallbackStatus
```

Returns the event callback status.

---

```motoko
mint(egg : NftEgg) : Text
```

Mints a new NFT. Assigns the hub as owner if none is given.

---

```motoko
transfer(to : Principal, id : Text) : Result.Result<(), Error> 
```

Transfers one of your own NFTs to another principal.

---

```motoko
authorize(req : AuthorizeRequest) : async Result.Result<(), Error>
```

Allows the caller to authorize another principal to act on its behalf.

---

```motoko
writeStaged(data : StagedWrite)
```

Writes a part of an NFT to the staged data.
*NOTE*: Initializing another NFT will destruct the data in the buffer.

---

```motoko
assetRequest(data : AssetRequest)
```

Allows you to replace delete and stage NFTs.

---

```motoko
getContractInfo() : ContractInfo
```

Returns the contract info which includes: heap size, memory size, total minted, cycles, etc... (see `ContractInfo`).

---

```motoko
listAssets() : [(Text, Text, Nat)]
```

List all the **static** assets.

---

```motoko
tokenByIndex(id : Text) : Result.Result<PublicNft, Error>
```

Gets the token with the given identifier.

---

```motoko
tokenChunkByIndex(id : Text, page : Nat) : async ChunkResult
```

Gets the token chuck with the given identifier and page number.

## Http Request

### `/nft/{id}`

Returns the NFT with the given `{id}`.

### `{static}`

Returns the static asset at the given path.

```motoko
public query func http_request(request : Http.Request) : async Http.Response
```

```motoko
type HeaderField = (Text, Text);

type Request = {
    body    : Blob;
    headers : [HeaderField];
    method  : Text;
    url     : Text;
};

Response = {
    body               : Blob;
    headers            : [HeaderField];
    status_code        : Nat16;
    streaming_strategy : ?StreamingStrategy;
};
```

### Streaming Strategy

Sometimes an NFT needs to be devided into chunk because it is too large. In this case a streaming strategy gets passed in the HTTP reponse.

```motoko
public type StreamingStrategy = {
    #Callback: {
        token    : StreamingCallbackToken;
        callback : StreamingCallback;
    };
};
```

In this case a callback is provided with a token and a callback that can be used to retreive the binary data corresponding with that token.

```motoko
public type StreamingCallback = query (StreamingCallbackToken) -> async (StreamingCallbackResponse);

public type StreamingCallbackToken =  {
    content_encoding : Text;
    index            : Nat;
    key              : Text;
};

public type StreamingCallbackResponse = {
    body  : Blob;
    token : ?StreamingCallbackToken;
};
```

You can find an [example](./examples/streaming.mo) in the [examples directory](./examples/).
