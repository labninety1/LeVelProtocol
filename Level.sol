// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0; 

import "solady/src/utils/LibPRNG.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./ILP.sol";
import "./IFold.sol";
import "./IFoldStaking.sol";
import "./IFoldAdmin.sol";
import "./IRouter.sol";

/*
* @title Ninety1
* @author lileddie.eth
*/
contract Level is ERC1155, Ownable, ReentrancyGuard {

    using LibPRNG for *;

    // Contract Parameters
    string private _name;
    string private _symbol;
    address DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Mint Parameters
    bool MINT_OPEN = false;
    uint256 public MINT_PRICE = 1 ether;
    uint256 public PAWN_MINT_PRICE = 0.2 ether;

    // Utility Parameters
    uint256 public BASIS_POINTS = 1e6;
    uint256 public TOTAL_PAWNS_BURNED = 0;

    // Dev Income Parameters
    uint256 public DEV_SHARE = 35; // Percentage of PAWN Income allocated to Dev.
    uint256 public DEV_BALANCE = 0; // Total Dev balance

    // Level System Parameters
    uint256 BUY_DEADLINE = 120; // LP Buying deadling
    uint256 BUY_THRESHOLD = 20 ether; // Buy $FLD When AVAX hits this.
    uint256 MIN_FOLD_THRESHOLD =  11111 ether; // Buy $FLD instead of LPing if FLD balance is below this.
    uint256 MIN_AVAX_THRESHOLD =  20 ether; // Only process any LPing or Buying when AVAX is above this.

    // FLD Burning
    uint256 BURN_PERCENT = 10; // Percent of FLD balance to burn.
    uint256 FOLD_BALANCE_THRESHOLD = 3; // % of supply held. Burn if balance is above this amount when updateLevel is called

    // Holder Tracking
    mapping (address => uint256) public addressPosition; // Score value of the NFTs a holder has.
    uint256 public totalScore;

    // Token Tracking
    struct LevelNFT {
        uint256 tokenID;
        string tokenName;
        uint256 tier;
        uint256 score;
    }
    uint256[] public availableTokenIDs; // Array of all available Level NFTs that can be minted.
    mapping(uint256 => LevelNFT) public tokenDataByID; // Data for all Token IDs
    uint256 tokenDataLength = 31; // Util to assist token iterations in tokenDataByID
    
    // Related Contracts
    IFold FOLD;
    IFoldStaking FOLD_STAKING;
    address TWENTY;
    address NINETY;
    IFoldAdmin FOLD_ADMIN;

    // LP Tracking
    address[] public LPS; // All LP Pool addresses
    mapping(address => address) public ROUTERS; // LP Pool => Router
    mapping(address => string) public RouterTokenName; // Router => LP Function...





    //
    // LEVEL Minting + Combining
    //


    /**
    * @param _amount quantity to mint
    */
    function mint(uint256 _amount) external payable nonReentrant {
        if(_amount == 0){ revert("Trying to mint 0"); }
        if(_msgSender() != tx.origin){ revert("Contracts cannot mint"); }
        if(!MINT_OPEN){ revert("Sale Closed"); }
        if(MINT_PRICE * _amount > msg.value){ revert("Not Enough Funds Sent"); }
        if(_amount > availableTokenIDs.length){ revert("Not enough left"); }

        LibPRNG.PRNG memory prng;
        prng.seed(randomSeed());

        for(uint a = 0;a < _amount;a++){
            uint256 randomIndex = prng.next() % availableTokenIDs.length;
            uint256 tokenToMint = availableTokenIDs[randomIndex];
            availableTokenIDs[randomIndex] = availableTokenIDs[availableTokenIDs.length - 1];
            availableTokenIDs.pop();
            _mint(_msgSender(), tokenToMint, 1,"");
        }

        updateLevel();
    }

    
    /**
    * @param _amount quantity to mint
    */
    function mintPawn(uint256 _amount) external payable nonReentrant {
        if(_amount == 0){ revert("Trying to mint 0"); }
        if(_msgSender() != tx.origin){ revert("Contracts cannot mint"); }
        if(!MINT_OPEN){ revert("Sale Closed"); }
        if(PAWN_MINT_PRICE * _amount > msg.value){ revert("Not Enough Funds Sent"); }

        _mint(_msgSender(), 0, _amount,"");

        DEV_BALANCE += (msg.value * DEV_SHARE) / 100;

        updateLevel();
    }


    /**
    * @param _amount quantity to mint - i.e. 2 will mint 2 of the next tier, burning 4 x _tokenId.
    * @param _tokenId ID of the token that will be burned for fusion
    */
    function fusion(uint256 _tokenId, uint256 _amount) external nonReentrant {
        uint256 totalFused = _amount * 4;
        if(_amount == 0){ revert("Trying to output 0"); }
        if(_msgSender() != tx.origin){ revert("Contracts cannot mint"); }
        if(balanceOf(_msgSender(),_tokenId) < totalFused){ revert("Not Enough Tokens Held"); }

        LevelNFT memory tokenData = tokenDataByID[_tokenId];
        LevelNFT memory nextTier = tokenDataByID[_tokenId + 1];

        uint256 pawnCost = 4;

        if(stringMatch(tokenData.tokenName, "SET")){
            if(tokenData.tier == 1) pawnCost = 6;
            if(tokenData.tier == 2) pawnCost = 18;
            if(tokenData.tier == 3) pawnCost = 54;
            if(tokenData.tier == 4) pawnCost = 150;
        }else{
            if(tokenData.tier == 2) pawnCost = 10;
            if(tokenData.tier == 3) pawnCost = 30;
            if(tokenData.tier == 4) pawnCost = 88;
        }

        pawnCost = pawnCost * _amount;

        if(balanceOf(_msgSender(),0) < pawnCost){ revert("Not Enough Pawns"); }

        if( (stringMatch(nextTier.tokenName,tokenData.tokenName)) && (nextTier.tier == tokenData.tier + 1) ){

            _burn(_msgSender(),0,pawnCost);
            _burn(_msgSender(),_tokenId,totalFused);

            _mint(_msgSender(), nextTier.tokenID, _amount,"");
        }else{
            revert("No route to fuse.");
        }
        
    }

    
    /**
    * @param _tier the tier being synthesised
    * @param _amount quantity of new tier to mint
    */
    function synthesis(uint256 _tier, uint256 _amount) external nonReentrant {

        if(_amount == 0){ revert("Trying to output 0"); }
        if(_msgSender() != tx.origin){ revert("Contracts cannot mint"); }

        uint256 pawnCost = 4;
        if(_tier == 2) pawnCost = 6;
        if(_tier == 3) pawnCost = 18;
        if(_tier == 4) pawnCost = 54;
        if(_tier == 5) pawnCost = 150;
        pawnCost = pawnCost * _amount;

        if(balanceOf(_msgSender(),0) < pawnCost){ revert("Not Enough Pawns"); }

        for(uint i=0;i<tokenDataLength;i+=1){
            if( (tokenDataByID[i].tier == _tier) ){
                if(stringMatch(tokenDataByID[i].tokenName, "SET")){
                    _mint(_msgSender(), tokenDataByID[i].tokenID, _amount,"");
                }else{
                    _burn(_msgSender(),tokenDataByID[i].tokenID,_amount);
                }
            }
        }
        
        _burn(_msgSender(),0,pawnCost);
    }


    /**
    * @param _tier the tier being burned
    * @param _amount quantity of new tier to mint
    */
    function castling(uint256 _tier, uint256 _amount) external nonReentrant {

        if(_amount == 0){ revert("Trying to output 0"); }
        if(_msgSender() != tx.origin){ revert("Contracts cannot mint"); }
        if(_tier > 3){ revert("Must be tier 3 or below"); }
        
        uint256 pawnCost = 70;
        if(_tier == 2) pawnCost = 280;
        if(_tier == 3) pawnCost = 1120;
        pawnCost = pawnCost * _amount;

        if(balanceOf(_msgSender(),0) < pawnCost){ revert("Not Enough Pawns"); }

        uint256 rookCost = _amount * 4;

        for(uint i=0;i<tokenDataLength;i+=1){
            if( (tokenDataByID[i].tier == _tier) && stringMatch(tokenDataByID[i].tokenName, "ROOK")){
                if(balanceOf(_msgSender(),tokenDataByID[i].tokenID) < rookCost){
                    revert("Missing required ROOKS");
                }else{
                    _burn(_msgSender(),tokenDataByID[i].tokenID,rookCost);
                }
            }
            if( (tokenDataByID[i].tier == _tier) && stringMatch(tokenDataByID[i].tokenName, "KING")){
                if(balanceOf(_msgSender(),tokenDataByID[i].tokenID) < 1){
                    revert("Missing required KING");
                }else{
                    _burn(_msgSender(),tokenDataByID[i].tokenID,_amount);
                }
            }
            
            if( (tokenDataByID[i].tier == _tier+2) && stringMatch(tokenDataByID[i].tokenName, "KING")){
                _mint(_msgSender(), tokenDataByID[i].tokenID, _amount,"");
            }
        }
        _burn(_msgSender(),0,pawnCost);
    }







    //
    // LEVEL System Functions
    //


    function updateLevel() public {
        
        FOLD_STAKING.updatePool();
        uint256 rewardsDue = FOLD_STAKING.pendingRewards(address(this));
        FOLD_STAKING.claimSelfFoldToken();
        FOLD_ADMIN.depositLevelClaimedFold(rewardsDue);

        // set balances after claiming
        uint256 AVAX_BALANCE = address(this).balance - DEV_BALANCE;
        uint256 FOLD_BALANCE = FOLD.balanceOf(address(this));

        // Only process LP logic if we have worthwhile amounts of AVAX
        if(AVAX_BALANCE >= MIN_AVAX_THRESHOLD){

            // Buy FOLD if we dont have enough sensible enough for LP use.
            if(FOLD_BALANCE < MIN_FOLD_THRESHOLD){
                buyFold(AVAX_BALANCE/2);
            }else{
                // find the LP with least FLD - we want to always provide liquidity to that LP.
                (ILP lpPoolToProvide, IRouter lpPoolToProvideRouter) = getSmallestLP();

                // Add max liquidity to the LP - checking if LP uses ETH or AVAX naming conventions
                if(stringMatch(RouterTokenName[address(lpPoolToProvideRouter)], "ETH")){
                    (,, uint256 liquidity) = lpPoolToProvideRouter.addLiquidityETH{value:AVAX_BALANCE}(address(FOLD),FOLD_BALANCE,0,0,address(this),(block.timestamp + BUY_DEADLINE));
                    FOLD_STAKING.depositLP(liquidity, address(lpPoolToProvide));
                }else{
                    (,, uint256 liquidity) = lpPoolToProvideRouter.addLiquidityAVAX{value:AVAX_BALANCE}(address(FOLD),FOLD_BALANCE,0,0,address(this),(block.timestamp + BUY_DEADLINE));
                    FOLD_STAKING.depositLP(liquidity, address(lpPoolToProvide));
                }

                // If our balance is above the threshold of excess FLD allowed to sit on the contract we burn the specified percentage.
                FOLD_BALANCE = FOLD.balanceOf(address(this));
                if(FOLD_BALANCE > calculateBurnThreshold()){
                    uint256 amountToBurn = (FOLD_BALANCE * BURN_PERCENT) / 100;
                    FOLD.transfer(DEAD_ADDRESS,amountToBurn);
                }
                
                // If we have excess balance of avax after LPing and the excess exceeds our threshold, we use half of it to BUY $fld for next time.
                AVAX_BALANCE = address(this).balance - DEV_BALANCE;
                if(AVAX_BALANCE >= BUY_THRESHOLD){
                    buyFold(AVAX_BALANCE/2);
                } 
            }
        }
        
    }

    function calculateBurnThreshold() public view returns(uint256 _amount){
        uint256 totalFold = FOLD.totalSupply();
        uint256 lockedSupply = FOLD.balanceOf(address(FOLD_STAKING));
        lockedSupply += FOLD.balanceOf(TWENTY);
        lockedSupply += FOLD.balanceOf(NINETY);
        uint256 circCupply = totalFold - lockedSupply;

        _amount = (circCupply * FOLD_BALANCE_THRESHOLD) / 100;
    }

    
    function getSmallestLP() internal view returns(ILP lpPoolToProvide, IRouter lpPoolToProvideRouter) {
        uint256 smallestLpFldSize = 2**256 - 1;

        if(LPS.length > 0){
            for(uint i = 0;i < LPS.length; i+=1){
                if(FOLD_STAKING.isValidLP(LPS[i])){
                    ILP lpPool = ILP(LPS[i]);
                    (uint112 _reserve0, uint112 _reserve1,) = lpPool.getReserves();

                    if(lpPool.token0() == address(FOLD)){
                        if(_reserve0 < smallestLpFldSize){
                            smallestLpFldSize = _reserve0;
                            lpPoolToProvide = lpPool;
                        }
                    }
                    else if(lpPool.token1() == address(FOLD)){
                        if(_reserve1 < smallestLpFldSize){
                            smallestLpFldSize = _reserve1;
                            lpPoolToProvide = lpPool;
                        }
                    }
                }
            }
            
            lpPoolToProvideRouter = IRouter(ROUTERS[address(lpPoolToProvide)]);
        }

        return (lpPoolToProvide, lpPoolToProvideRouter);
    }


    function buyFold(uint256 avaxSpend) internal {
        uint256 largestLpFldSize = 0;
        uint256 largestLpAvaxSize = 0;
        ILP lpPoolToBuy;
        IRouter lpPoolToBuyRouter;
        uint256 deadline = block.timestamp + BUY_DEADLINE;

        for(uint i = 0;i < LPS.length; i+=1){
            if(FOLD_STAKING.isValidLP(LPS[i])){
                ILP lpPool = ILP(LPS[i]);
                (uint112 _reserve0, uint112 _reserve1,) = lpPool.getReserves();

                if(lpPool.token0() == address(FOLD)){
                    if(_reserve0 > largestLpFldSize){
                        largestLpFldSize = _reserve0;
                        largestLpAvaxSize = _reserve1;
                        lpPoolToBuy = lpPool;
                    }
                }
                else if(lpPool.token1() == address(FOLD)){
                    if(_reserve1 > largestLpFldSize){
                        largestLpFldSize = _reserve1;
                        largestLpAvaxSize = _reserve0;
                        lpPoolToBuy = lpPool;
                    }
                }
            }
        }
        
        lpPoolToBuyRouter = IRouter(ROUTERS[address(lpPoolToBuy)]);
        

        address[] memory path = new address[](2);
        if(stringMatch(RouterTokenName[address(lpPoolToBuyRouter)], "ETH")){
            path[0] = lpPoolToBuyRouter.WETH();
        }else{
            path[0] = lpPoolToBuyRouter.WAVAX();
        }
        path[1] = address(FOLD);

        if(stringMatch(RouterTokenName[address(lpPoolToBuyRouter)], "ETH")){
            lpPoolToBuyRouter.swapExactETHForTokens{value:avaxSpend}(0,path,address(this),deadline);
        }else{
            lpPoolToBuyRouter.swapExactAVAXForTokens{value:avaxSpend}(0,path,address(this),deadline);
        }
    }

    
    function resupplyLevelTokens(uint tokenId, uint _amount) internal {
        if(availableTokenIDs.length + _amount > 2652) revert("Too many tokens specified");

        for(uint i = 0;i < _amount; i++){
            availableTokenIDs.push(tokenId);
        }
    }





    //
    // Holding Exit Functions
    //

    function withdraw(uint256[] calldata _tokenIds, uint256[] calldata _amounts, bool _withdrawFromLP) external {
        
        if(_tokenIds.length == 0){ revert("No tokens provided"); }
        if(_tokenIds.length != _amounts.length){ revert("Token ID and Amounts dont match in size"); }

        uint256 basedShare = getNFTShare(_tokenIds, _amounts);

        uint256 pawnCost = 0;
        uint256 pawnBalance = balanceOf(_msgSender(),0);

        for(uint i=0;i<_tokenIds.length;i+=1){
            if(tokenDataByID[_tokenIds[i]].tier == 1){
                pawnCost += 1 * _amounts[i];
            }else if(tokenDataByID[_tokenIds[i]].tier == 2){
                pawnCost += 2 * _amounts[i];
            }else if(tokenDataByID[_tokenIds[i]].tier == 3){
                pawnCost += 8 * _amounts[i];
            }else if(tokenDataByID[_tokenIds[i]].tier == 4){
                pawnCost += 32 * _amounts[i];
            }else if(tokenDataByID[_tokenIds[i]].tier == 5){
                pawnCost += 128 * _amounts[i];
            }
            if(pawnCost > pawnBalance){
                revert("Not enough Pawns");
            }
            _burn(_msgSender(),_tokenIds[i],_amounts[i]);
        }
        
        _burn(_msgSender(),0,pawnCost);

        doWithdraw(_withdrawFromLP, basedShare);

    }

    
    function withdrawAll(bool _withdrawFromLP) external {
        uint256 basedShare = getShare(_msgSender());

        
        if(basedShare == 0){ revert("No shares of level"); }
                
        uint256 pawnCost = 0;
        uint256 pawnBalance = balanceOf(_msgSender(),0);

        // Burn all the NFTs - except pawns here.
        for(uint i=1;i<tokenDataLength;i+=1){
            uint256 tokenBalance = balanceOf(_msgSender(),tokenDataByID[i].tokenID);
            if(tokenBalance > 0){
                if(tokenDataByID[i].tier == 1){
                    pawnCost += 1 * tokenBalance;
                }else if(tokenDataByID[i].tier == 2){
                    pawnCost += 2 * tokenBalance;
                }else if(tokenDataByID[i].tier == 3){
                    pawnCost += 8 * tokenBalance;
                }else if(tokenDataByID[i].tier == 4){
                    pawnCost += 32 * tokenBalance;
                }else if(tokenDataByID[i].tier == 5){
                    pawnCost += 128 * tokenBalance;
                }
                if(pawnCost > pawnBalance){
                    revert("Not enough Pawns");
                }
                _burn(_msgSender(),tokenDataByID[i].tokenID,tokenBalance);
            }
        }
        
        _burn(_msgSender(),0,pawnCost);

        // Just ensure position is zerod out.
        addressPosition[_msgSender()] = 0;

        doWithdraw(_withdrawFromLP, basedShare);
    }
    
    function doWithdraw(bool _withdrawFromLP, uint256 _share) internal {
        for(uint i=0;i<LPS.length;i+=1){
            address lpAddress = LPS[i];
            uint256 lpTotal = FOLD_STAKING.LPStakes(lpAddress, address(this));
            if(lpTotal > 1) {
                uint256 withdrawAmount = (lpTotal * _share) / (100 * BASIS_POINTS);
                FOLD_STAKING.withdrawLP(withdrawAmount, lpAddress);
                
                if(_withdrawFromLP){
                    // withdraw from pool
                    IRouter lpRouter = IRouter(ROUTERS[lpAddress]);
                    
                    if(stringMatch(RouterTokenName[address(lpRouter)], "ETH")){
                        lpRouter.removeLiquidityETH(address(FOLD),withdrawAmount,0,0,_msgSender(),(block.timestamp + BUY_DEADLINE));
                    }else{
                        lpRouter.removeLiquidityAVAX(address(FOLD),withdrawAmount,0,0,_msgSender(),(block.timestamp + BUY_DEADLINE));
                    }
                }else{
                    // transfer the LP tokens
                    IERC20(lpAddress).transfer(_msgSender(), withdrawAmount);
                }
            }
        }
    }




    //
    // Admin Functions
    //

    
    function withdrawDevFee() external onlyOwner {
        uint256 balance = DEV_BALANCE;
        (bool sent, ) = msg.sender.call{value: balance}("");
        require(sent, "Failed to send Avax to Wallet");
        DEV_BALANCE = 0;
    }


    function addLP(address _lpAddress, address _routerAddress, string memory _routerTokenName) public onlyOwner {
        LPS.push(_lpAddress);
        ROUTERS[_lpAddress] = _routerAddress;
        RouterTokenName[_routerAddress] = _routerTokenName;

        uint256 MAX_INT = 2**256 - 1;
        FOLD.approve(_routerAddress,MAX_INT);

        ILP theLP = ILP(_lpAddress);
        theLP.approve(address(FOLD_STAKING),MAX_INT);
        theLP.approve(_routerAddress,MAX_INT);
    }


    function removeLP(address _lpAddress) external onlyOwner {
        address routerAddress = ROUTERS[_lpAddress];
        delete RouterTokenName[routerAddress];
        delete ROUTERS[_lpAddress];

        for(uint i=0;i<LPS.length;i+=1){
            if(LPS[i] == _lpAddress){
                LPS[i] = LPS[LPS.length-1];
                LPS.pop();
                break;
            }
        }
        FOLD.approve(routerAddress,0);

        ILP theLP = ILP(_lpAddress);
        theLP.approve(address(FOLD_STAKING),0);
        theLP.approve(routerAddress,0);
    }




    //
    // UI Functions
    //

    function getShare(address _holder) public view returns(uint256 _share) {
        return ((addressPosition[_holder] * BASIS_POINTS) / totalScore) * 100;
    }

    function getNFTShare(uint256[] calldata _tokenIds, uint256[] calldata _amounts) public view returns(uint256 _share) {
        
        uint256 total = 0;
        for(uint256 i = 0;i<_tokenIds.length;i+=1){
            total += tokenDataByID[_tokenIds[i]].score * _amounts[i];
        }

        return ((total * BASIS_POINTS) / totalScore) * 100;
    }


    function getAvailableSupplyCount() external view returns(uint256 _supplyCount){
        return availableTokenIDs.length;
    }






    //
    // Token Transfer Handling
    //

    function _afterTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {

        uint256 scoreAdjustment = 0;

        for(uint256 i = 0;i<ids.length;i+=1){            
            LevelNFT memory tokenData = tokenDataByID[ids[i]];
            scoreAdjustment += tokenData.score * amounts[i];
            
            if(to == DEAD_ADDRESS || to == address(0)){
                if(tokenData.tokenID == 0){
                    TOTAL_PAWNS_BURNED += amounts[i];
                }
                if(tokenData.tier == 1 && !stringMatch(tokenData.tokenName, "SET") ){
                    resupplyLevelTokens(tokenData.tokenID,amounts[i]);
                }
            }
        }

        if(to == DEAD_ADDRESS || to == address(0)){
            totalScore -= scoreAdjustment;
            addressPosition[from] -= scoreAdjustment;
            
        }
        else if(from == address(0)){
            totalScore += scoreAdjustment;
            addressPosition[to] += scoreAdjustment;
        }   
        else {  
            addressPosition[from] -= scoreAdjustment;
            addressPosition[to] += scoreAdjustment;
        } 
    }





    //
    // Setters
    //


    function setBaseURI(string memory _uri) external onlyOwner {
        _setURI(_uri);
    }
    function setContracts(address _addressStaking, address _addressFold, address _addressFoldAdmin, address _twenty, address _ninety) public onlyOwner {
        FOLD_STAKING = IFoldStaking(_addressStaking);
        FOLD = IFold(_addressFold);
        FOLD_ADMIN = IFoldAdmin(_addressFoldAdmin);
        TWENTY = _twenty;
        NINETY = _ninety;
    }
    function setDevShare(uint256 _percent) external onlyOwner {
        DEV_SHARE = _percent;
    }    
    function setMintingOpen(bool _isOpen) external onlyOwner {
        MINT_OPEN = _isOpen;
    }
    function setBuyDeadline(uint256 _seconds) external onlyOwner {
        BUY_DEADLINE = _seconds;
    }
    function setMintPrice(uint256 _price) external onlyOwner {
        MINT_PRICE = _price;
    }
    function setPawnMintPrice(uint256 _price) external onlyOwner {
        PAWN_MINT_PRICE = _price;
    }
    function setMinFoldThreshold(uint256 _amount) external onlyOwner {
        MIN_FOLD_THRESHOLD = _amount;
    }
    function setMinAvaxThreshold(uint256 _amount) external onlyOwner {
        MIN_AVAX_THRESHOLD = _amount;
    }
    function setBuyThreshold(uint256 _amount) external onlyOwner {
        BUY_THRESHOLD = _amount;
    }
    function setBurnPercent(uint256 _percent) external onlyOwner {
        BURN_PERCENT = _percent;
    }
    function setBurnThresholdPercent(uint256 _percent) external onlyOwner {
        FOLD_BALANCE_THRESHOLD = _percent;
    }
    function setAvailableTokens(uint tokenId, uint _amount) external onlyOwner {
        if(availableTokenIDs.length + _amount > 2652) revert("Too many tokens specified");

        for(uint i = 0;i < _amount; i++){
            availableTokenIDs.push(tokenId);
        }
    }





    //
    // Utils
    //

    function stringMatch(string memory _a, string memory _b) internal virtual returns (bool) {
        if (keccak256(abi.encodePacked(_a)) == keccak256(abi.encodePacked(_b))) {
            return true;
        }else{
            return false;
        }
    }


    function randomSeed() internal view returns(uint) {
        return uint(
            keccak256(
                abi.encodePacked(
                    tx.gasprice,
                    block.number,
                    block.timestamp,
                    block.prevrandao,
                    blockhash(block.number - 1),
                    msg.sender
                )
            )
        );
    }






    //
    // Basic Contract Functions
    //

   
    /**
     * @dev Returns the token collection name.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the token collection symbol.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }
    
    receive() external payable  {}

    fallback() external payable {}

    constructor() ERC1155("https://enefte.info/n1/level.php?token_id=") {
        _name = "Level";
        _symbol = "LVL";

        tokenDataByID[0] = LevelNFT(0,"PAWN",0,0);

        tokenDataByID[1] = LevelNFT(1,"KING", 1, 1 ether);
        tokenDataByID[2] = LevelNFT(2,"KING", 2, 4.944 ether);
        tokenDataByID[3] = LevelNFT(3,"KING", 3, 22.112 ether);
        tokenDataByID[4] = LevelNFT(4,"KING", 4, 96 ether);
        tokenDataByID[5] = LevelNFT(5,"KING", 5, 414.208 ether);

        tokenDataByID[6] = LevelNFT(6,"KNIGHT",1,1.236 ether);
        tokenDataByID[7] = LevelNFT(7,"KNIGHT",2,6.110784 ether);
        tokenDataByID[8] = LevelNFT(8,"KNIGHT",3,27.330432 ether);
        tokenDataByID[9] = LevelNFT(9,"KNIGHT",4,118.656 ether);
        tokenDataByID[10] = LevelNFT(10,"KNIGHT",5,511.961088 ether);

        tokenDataByID[11] = LevelNFT(11,"BISHOP",1,1.382 ether);
        tokenDataByID[12] = LevelNFT(12,"BISHOP",2,6.832608 ether);
        tokenDataByID[13] = LevelNFT(13,"BISHOP",3,30.558784 ether);
        tokenDataByID[14] = LevelNFT(14,"BISHOP",4,132.672 ether);
        tokenDataByID[15] = LevelNFT(15,"BISHOP",5,572.435456 ether);

        tokenDataByID[16] = LevelNFT(16,"ROOK",1,1.618 ether);
        tokenDataByID[17] = LevelNFT(17,"ROOK",2,7.999392 ether);
        tokenDataByID[18] = LevelNFT(18,"ROOK",3,35.777216 ether);
        tokenDataByID[19] = LevelNFT(19,"ROOK",4,155.328 ether);
        tokenDataByID[20] = LevelNFT(20,"ROOK",5,670.188544 ether);

        tokenDataByID[21] = LevelNFT(21,"QUEEN",1,1.786 ether);
        tokenDataByID[22] = LevelNFT(22,"QUEEN",2,8.829984 ether);
        tokenDataByID[23] = LevelNFT(23,"QUEEN",3,39.492032 ether);
        tokenDataByID[24] = LevelNFT(24,"QUEEN",4,171.456 ether);
        tokenDataByID[25] = LevelNFT(25,"QUEEN",5,739.775488 ether);

        tokenDataByID[26] = LevelNFT(26,"SET",1,8.679192 ether);
        tokenDataByID[27] = LevelNFT(27,"SET",2,38.817616 ether);
        tokenDataByID[28] = LevelNFT(28,"SET",3,168.528 ether);
        tokenDataByID[29] = LevelNFT(29,"SET",4,727.142144 ether);
        tokenDataByID[30] = LevelNFT(30,"SET",5,3210.570752 ether);
        
    }

}