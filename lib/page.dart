import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cross_file/cross_file.dart';
import 'package:dartx/dartx.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_share/file_size.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:install_plugin/install_plugin.dart';
import 'package:path_provider/path_provider.dart';

class SharePage extends StatefulWidget {
  const SharePage({super.key});

  @override
  State<StatefulWidget> createState() {
    return _PageState();
  }
}

class Record {
  final String sender;
  final String name;
  final int size;
  final bool isSender;
  int receiveSize = 0;
  final String path;

  Record({
    required this.path,
    required this.name,
    required this.size,
    required this.isSender,
    required this.sender,
  });

  @override
  String toString() {
    return 'Record{name: $name, isSender: $isSender, size: $size}';
  }
}

class _PageState extends State<SharePage> {
  late RawDatagramSocket _rawDatagramSocket;
  late ServerSocket _serverSocket;
  var DESTINATION_ADDRESS = InternetAddress("192.168.0.255");
  late InternetAddress localInternetAddress;

  Timer? _broadcastMyselfTimer;

  late String name;

  List<Pair<String, InternetAddress>> devices = List.empty(growable: true);
  List<Record> records = List.empty(growable: true);

  @override
  void initState() {
    name =
        List.generate(4, (_) => Random().nextInt(16).toRadixString(16)).join();
    Future.microtask(() async {
      _serverSocket = await ServerSocket.bind("0.0.0.0", 2334);
      _serverSocket.listen((socket) async {
        final socketStream = socket.asBroadcastStream();
        final first = await socketStream.first;
        if (first[0] == 0x01) {
          var string = utf8.decode(first.sublist(1));
          Map<String, dynamic> map = jsonDecode(string);
          final fileName = map['filename'] as String;
          final fileSize = map['filesize'] as int;
          final sender =
              "${devices.firstOrNullWhere((d) => d.second == socket.remoteAddress)?.first ?? "${socket.remoteAddress}"}";
          final bool? willReceive = await showCupertinoDialog(
              context: context,
              barrierDismissible: true,
              builder: (context) {
                return CupertinoAlertDialog(
                  title: Text("提示"),
                  content: Text("$sender想要给您传输文件[$fileName($fileSize)]，是否要接收?"),
                  actions: [
                    CupertinoDialogAction(
                        isDestructiveAction: true,
                        child: Text("取消"),
                        onPressed: () {
                          Navigator.of(context).pop(false);
                        }),
                    CupertinoDialogAction(
                        child: Text("确定"),
                        onPressed: () {
                          Navigator.of(context).pop(true);
                        }),
                  ],
                );
              });
          if (willReceive == true) {
            socket.add([0x01]);
            final dir = await getDownloadsDirectory();
            final path = "${dir!.path}/$fileName";
            File file = File(path);
            final ioSink = file.openWrite();
            final record = Record(
                path: path,
                sender: sender,
                name: fileName,
                size: fileSize,
                isSender: false);
            records.add(record);
            socketStream.listen((data) {
              print("receive file:${data.length}");
              record.receiveSize += data.length;
              ioSink.add(data);
              setState(() {});
            }, onDone: () async {
              await ioSink.flush();
              await ioSink.close();
              print("onDone");
            });
          } else {
            socket.add([0x00]);
            await socket.close();
          }
        } else {
          socket.add([0x00]);
          await socket.close();
        }
      });

      List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false, // 是否包含回环接口
        includeLinkLocal: false, // 是否包含链路本地接口（例如IPv6的自动配置地址）。
        type: InternetAddressType.IPv4,
      );
      localInternetAddress = interfaces.first.addresses.first;
      _rawDatagramSocket = await RawDatagramSocket.bind("0.0.0.0", 2333);
      _rawDatagramSocket.broadcastEnabled = true;
      _rawDatagramSocket.listen((RawSocketEvent event) {
        //! 空断言运算符 将表达式转换为其基础的不可空类型，如果转换失败，则抛出运行时异常；
        if (event == RawSocketEvent.read) {
          final datagram = _rawDatagramSocket.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);

            if (datagram.address != localInternetAddress) {
              bool has = devices.any((p) => p.second == datagram.address);
              if (!has) {
                print(
                    "save:$message,${datagram.address}-${InternetAddress.loopbackIPv4}");
                devices.add(Pair(message, datagram.address));
                setState(() {});
              }
            }
          }
        }
        if (event == RawSocketEvent.write) {
          final datagram = _rawDatagramSocket.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            print("write:$message");
          }
        }
      });
      _broadcastMyselfTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        broadcastMyself();
      });
      broadcastMyself();
    });

    super.initState();
  }

  void broadcastMyself() {
    _rawDatagramSocket.send(utf8.encode("$name"), DESTINATION_ADDRESS, 2333);
  }

  void presentFile(InternetAddress address, String fileName, int fileSize) {
    Map map = {"type": "fileInfo", "fileName": fileName, "fileSize": fileSize};
    _rawDatagramSocket.send(utf8.encode(jsonEncode(map)), address, 2333);
  }

  int _draggingIndex = -1;

  @override
  void dispose() {
    _serverSocket.close();
    _broadcastMyselfTimer?.cancel();
    _rawDatagramSocket.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text("$name"),
            middle: const Text("File share"),
            trailing: IconButton(
                onPressed: () async {
                  devices.clear();
                  setState(() {

                  });
                },
                icon: const Icon(Icons.clear_all)),
          ),
          const PinnedHeaderSliver(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text("扫描设备中"),
            ),
          ),
          SliverList(
              delegate: SliverChildBuilderDelegate(
            (context, index) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropTarget(
                    onDragDone: (detail) {
                      if (detail.files.isNotEmpty){
                        sendTo(devices[index].second, detail.files.first);
                      }
                      setState(() {
                        _draggingIndex = -1;
                      });
                    },
                    onDragEntered: (detail) {
                      setState(() {
                        _draggingIndex = index;
                      });
                    },
                    onDragExited: (detail) {
                      setState(() {
                        _draggingIndex = -1;
                      });
                    },
                    child: CupertinoListTile(
                      title: Text("${devices[index].first}"),
                      onTap: () {
                        pickAndSendTo(devices[index].second);
                      },
                      trailing:
                      TextButton(onPressed: () {}, child: const Text("发送文件")),
                      backgroundColor: _draggingIndex == index ? Colors.blue.withOpacity(0.5) : null,
                    ),
                  ),
                  const Divider(
                    height: 1,
                  ),
                ],
              );
            },
            childCount: devices.length,
          )),
          const PinnedHeaderSliver(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text("收发记录"),
            ),
          ),
          SliverList(
              delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = records[index];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CupertinoListTile(
                    leading: Text(
                      item.isSender ? "发" : "收",
                      style: TextStyle(
                          color: item.isSender ? Colors.green : Colors.blue),
                    ),
                    title: Text("${item.name}"),
                    subtitle: Text("${filesize(item.receiveSize)}/${filesize(item.size)}"),
                    trailing: Text(
                        "${((item.receiveSize / item.size) * 100).toStringAsFixed(2)}%"),
                    additionalInfo: Text("${item.sender}"),

                    onTap: () async{
                      if (item.name.endsWith("apk")){
                          InstallPlugin.installApk(item.path);
                      }else{
                        await FilePicker.platform.saveFile(dialogTitle: "保存文件", fileName: item.name, bytes: await File(item.path).readAsBytesSync());
                        // final filePath = await FilePicker.platform.saveFile(dialogTitle: "保存文件", fileName: item.name, bytes: await File(item.path).readAsBytesSync());
                        // if (filePath != null){
                        //   File(item.path).copy(filePath);
                        // }
                      }
                    },
                  ),
                  const Divider(
                    height: 1,
                  ),
                ],
              );
            },
            childCount: records.length,
          )),
        ],
      ),
    );
  }

  Future sendTo(InternetAddress address, XFile file)async{
    try {
      Socket socket = await Socket.connect(address, 2334);
      socket.add([
        0x01,
        ...utf8.encode(
            jsonEncode({"filename": file.name, "filesize": await file.length()}))
      ]);
      final first = await socket.first;
      print("first:$first");
      if (first[0] == 0x01) {
        final sender =
            "${devices.firstOrNullWhere((d) => d.second == socket.remoteAddress)?.first ?? "${socket.remoteAddress}"}";
        final record = Record(
            path: file.path ?? "",
            name: file.name,
            size: await file.length(),
            isSender: true,
            sender: sender);
        records.add(record);
        setState(() {});
        await socket.addStream(file.openRead().map((s) {
          record.receiveSize += s.length;
          setState(() {});
          return s;
        }));
        await socket.close();
        // socket.add(file.bytes ?? []);
      } else {
        await socket.close();
        await showCupertinoDialog(
        context: context,
        barrierDismissible: true,
        builder: (context) {
          return CupertinoAlertDialog(
            title: Text("提示"),
            content: Text("对方拒绝接收文件"),
            actions: [
              CupertinoDialogAction(
                  child: Text("确定"),
                  onPressed: () {
                    Navigator.of(context).pop(true);
                  }),
            ],
          );
        });
      }
    } catch (e) {
      await showCupertinoDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return CupertinoAlertDialog(
          title: Text("提示"),
          content: Text("发送失败:${e}"),
          actions: [
            CupertinoDialogAction(
                child: Text("确定"),
                onPressed: () {
                  Navigator.of(context).pop(true);
                }),
          ],
        );
      });
    }
  }

  void pickAndSendTo(InternetAddress address) async {
    final pickerResult = await FilePicker.platform.pickFiles();
    if (pickerResult != null) {
      if (pickerResult.files.isNotEmpty) {
        final file = pickerResult.files.first;
        await sendTo(address, file.xFile);
      }
    }
  }
}


