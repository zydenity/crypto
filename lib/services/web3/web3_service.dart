import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';

class Web3Service {
  // Replace with your own (Infura/Alchemy/Ankr) when ready.
  static const _rpcUrl = "https://rpc.ankr.com/eth";
  final _client = Web3Client(_rpcUrl, http.Client());

  Future<EtherAmount> getEthBalance(String address) async {
    final addr = EthereumAddress.fromHex(address);
    return _client.getBalance(addr);
  }

  Future<String?> connectWallet() async {
    // TODO: WalletConnect v2 integration here
    return null;
  }

  void dispose() => _client.dispose();
}
