library local_post_management;

export 'queue_model.dart';
export 'post_model.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_post_management/error_handling_util.dart';
import 'package:local_post_management/network.dart';
import 'package:local_post_management/post_model.dart';
import 'package:local_post_management/queue_model.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:http/http.dart' as http;

/// A Calculator.
class LocalPostManagement {
  Directory? directory;
  QueueStatus queueStatus = QueueStatus.idle;
  List<QueueModel> queue = [];
  StreamController<List<QueueModel>> queueController =
      StreamController<List<QueueModel>>.broadcast();
  StreamController<QueueStatus> queueStatusController =
      StreamController<QueueStatus>.broadcast();
  ValueChanged<QueueStatus> onSendingSuccess = (QueueStatus status) {};
  ValueChanged<QueueStatus> onSendingError = (QueueStatus status) {};
  ValueChanged<QueueStatus> onError = (QueueStatus status) {};
  bool? isSequential;
  String? name;
  bool? removeData;
  Map<String, dynamic> Function()? replaceHeader;
  Duration delayed = const Duration(seconds: 2);
  List<int> skipSquential = [];

  LocalPostManagement() {
    queueStatusController.add(queueStatus);
  }

  Future<void> initialize(
    bool isSequential,
    String name, {
    bool? removeData = true,
    Map<String, dynamic> Function()? replaceHeader,
    List<int> skipSquential = const [],
    Duration delayed = const Duration(seconds: 2),
  }) {
    //set sequential
    this.removeData = removeData;
    this.isSequential = isSequential;
    this.replaceHeader = replaceHeader;
    this.skipSquential = skipSquential;
    this.delayed = delayed;
    queueStatusController.add(queueStatus);
    return getApplicationDocumentsDirectory().then((value) {
      //chek apakah directory 'localpostqueue' sudah ada
      this.name = name;
      directory = Directory('${value.path}/$name');
      if (!directory!.existsSync()) {
        //jika belum ada, buat directory 'antrian'
        directory!.createSync();
      }
    });
  }

  Future<void> reiInitialize() {
    //set sequential
    queueStatusController.add(queueStatus);
    return getApplicationDocumentsDirectory().then(
      (value) {
        //chek apakah directory 'localpostqueue' sudah ada
        directory = Directory('${value.path}/$name');
        if (!directory!.existsSync()) {
          //jika belum ada, buat directory 'antrian'
          directory!.createSync();
        }
      },
    );
  }

  Future<void> reset() {
    queueStatus = QueueStatus.idle;
    queueStatusController.add(queueStatus);
    queue = [];
    queueController.add(queue);
    return getApplicationDocumentsDirectory().then(
      (value) {
        //chek apakah directory 'localpostqueue' sudah ada
        directory = Directory('${value.path}/$name');
        if (!directory!.existsSync()) {
          //jika belum ada, buat directory 'antrian'
          directory!.createSync();
        } else {
          directory!.listSync().forEach((element) {
            element.deleteSync();
          });
          directory!.createSync();
        }
      },
    );
  }

  Future<List<QueueModel>> getQueue() {
    //format penamaan file [id]#[name]#[createdDate]#[uploadedDate]#[status].json
    List<QueueModel> queue = [];
    //dapatkan semua file pada directory 'localpostqueue'
    return directory!.list().toList().then((value) {
      //urutkan berdasarkan tanggal pembuatan
      value.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      //ambil file pertama
      for (FileSystemEntity file in value) {
        String fileName = file.path.split('/').last.split('.').first;
        try {
          queue.add(QueueModel(
            id: fileName.split('#')[0],
            name: file.path.split('#')[1],
            createdDate: DateTime.parse(fileName
                .split('#')[2]
                .replaceAll('_', ':')
                .replaceAll('--', '.')),
            uploadedDate: fileName.split('#')[3] == ''
                ? null
                : DateTime.parse(fileName
                    .split('#')[3]
                    .replaceAll('_', ':')
                    .replaceAll('--', '.')),
            status: fileName.split('#')[4],
            filePath: file.path,
          ));
        } catch (e) {
          debugPrint("format file not valid $e");
        }
      }
      return queue;
    });
  }

  Future<QueueModel> addQueue({
    required String? name,
    required PostModel postModel,
  }) {
    //format penamaan file [id]#[name]#[createdDate]#[uploadedDate]#[status].json
    String id = getNewId();
    String createdDate = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '_')
        .replaceAll('.', '--');
    String status = 'pending';
    String fileName = '$id#$name#$createdDate##$status.json';
    //buat file baru
    return File('${directory!.path}/$fileName').create().then(
      (value) {
        //tulis data ke file
        return value
            .writeAsString(jsonEncode(postModel.toJson()))
            .then((value) {
          //buat QueueModel
          return QueueModel(
            id: id,
            name: name,
            createdDate: DateTime.parse(
                createdDate.replaceAll('_', ':').replaceAll('--', '.')),
            uploadedDate: null,
            status: status,
            filePath: value.path,
          );
        });
      },
    );
  }

  //get queue and add to queue
  void loadQueue() {
    getQueue().then((value) {
      queue = value;
      queueController.add(queue);
    });
  }

  //get queue and add to queue
  void reLoadQueue() {
    queueController.add(queue);
  }

  //add and load queue
  Future<QueueModel> addAndLoadQueue({
    required String? name,
    required PostModel postModel,
  }) {
    return addQueue(name: name, postModel: postModel).then((value) {
      queue.add(value);
      queueController.add(queue);
      return value;
    });
  }

  //run queue, mulai menjalankan antrian
  void startQueue() {
    if (queueStatus == QueueStatus.running) {
      return;
    } else {
      queueStatus = QueueStatus.running;
      queueStatusController.add(queueStatus);
      runQueue();
    }
  }

  //stop queue, stop menjalankan antrian
  void stopQueue() {
    queueStatus = QueueStatus.idle;
    queueStatusController.add(queueStatus);
  }

  //run queue, mulai menjalankan antrian
  void runQueue() {
    if (queueStatus == QueueStatus.running) {
      QueueModel queueModel = QueueModel();
      //ambil antrian pertama
      try {
        queueModel = queue.firstWhere((element) => element.status == 'pending');
      } catch (e) {
        Future.delayed(delayed, () {
          runQueue();
        });
        return;
      }
      //ubah status antrian menjadi running
      queueModel.status = 'running';
      //update status antrian
      queueController.add(queue);
      //jalankan antrian
      //read post data model from file
      File(queueModel.filePath ?? "").readAsString().then(
        (value) {
          //upload post data model
          try {
            queueModel.status = 'sending';
            queueController.add(queue);
            PostModel postModel = PostModel.fromJson(json.decode(value));

            //check aapakah reolace header tidak null
            var replacementHeader = replaceHeader?.call() ?? {};

            //replace header
            if (replacementHeader.isNotEmpty) {
              //lopp header replacement
              replacementHeader.forEach((key, value) {
                //replace header
                postModel.headers[key] = value;
              });
            }

            Network.post(
              url: postModel.url!,
              body: postModel.body,
              headers: postModel.headers,
              querys: postModel.query,
            ).then((value) {
              //update sttus antrian menjadi success
              queueModel.status = 'success';
              queueModel.uploadedDate = DateTime.now();
              //update status antrian
              queueController.add(queue);
              if (removeData == true) {
                //hapus file antrian
                File(queueModel.filePath ?? "").deleteSync();
                //hapus antrian dari list antrian
                queue.remove(queueModel);
              } else {
                //rename file name
                queueModel.uploadedDate = DateTime.now();
                String fileName =
                    '${queueModel.id}#${queueModel.name}#${queueModel.createdDate!.toIso8601String().replaceAll(':', '_').replaceAll('.', '--')}##${queueModel.status}.json';
                File(queueModel.filePath ?? "")
                    .renameSync('${directory!.path}/$fileName');
                //update file path
                queueModel.filePath = '${directory!.path}/$fileName';
                //notify ke controller
              }
              //notify ke kontroller
              queueController.add(queue);
              //jalankan antrian berikutnya
              //send callback
              onSendingSuccess(queueStatus);
              //end callback
              runQueue();
            }).catchError((error) {
              postModel.statusCode = readStatusCode(error);
              debugPrint("statuscode error ${postModel.statusCode}");
              postModel.lastError = ErrorHandlingUtil.handleApiError(error);
              postModel.lastTryDate = DateTime.now();

              File(queueModel.filePath ?? "")
                  .writeAsString(jsonEncode(postModel.toJson()));
              //rename file name

              //jika jenis antrian sequential di nontaifkan maka antrian akan dilanjutkan dan antrian ini di set ke faied
              if (isSequential == false ||
                  skipSquential.contains(postModel.statusCode)) {
                queueModel.status = 'failed';
                String fileName =
                    '${queueModel.id}#${queueModel.name}#${queueModel.createdDate!.toIso8601String().replaceAll(':', '_').replaceAll('.', '--')}##${queueModel.status}.json';
                File(queueModel.filePath ?? "")
                    .renameSync('${directory!.path}/$fileName');
                //update file path
                queueModel.filePath = '${directory!.path}/$fileName';
                //notify ke controller
                queueController.add(queue);
                //send callback
                onError(queueStatus);
                //end callback
                runQueue();
              } else {
                queueModel.status = 'failed';
                //notify ke controller
                queueController.add(queue);
                //tinggu beberapa detik sebagai jedo pengiriman
                Future.delayed(delayed).then((value) {
                  //kembalikan jadi pending
                  queueModel.status = 'pending';
                  //notify ke controller
                  queueController.add(queue);
                  runQueue();
                });
              }
              //jalankan antrian berikutnya
            });
          } catch (e) {
            PostModel postModel = PostModel();
            postModel.statusCode = 900;
            postModel.lastError = ErrorHandlingUtil.handleApiError(e);
            postModel.lastTryDate = DateTime.now();
            queueModel.status = 'failed';
            //tulis ke file
            File(queueModel.filePath ?? "")
                .writeAsString(jsonEncode(postModel.toJson()));
            //rename file name
            queueModel.uploadedDate = DateTime.now();
            String fileName =
                '${queueModel.id}#${queueModel.name}#${queueModel.createdDate!.toIso8601String().replaceAll(':', '_').replaceAll('.', '--')}##${queueModel.status}.json';
            File(queueModel.filePath ?? "")
                .renameSync('${directory!.path}/$fileName');
            //update file path
            queueModel.filePath = '${directory!.path}/$fileName';
            //notify ke controller
            queueController.add(queue);
            //send callback
            onError(queueStatus);
            //end callback
            runQueue();
          }
        },
      ).catchError((onError) {
        debugPrint("errorread file $onError");
        runQueue();
      });
    }
  }

  static readStatusCode(dynamic error) {
    if (error is http.Response) {
      return error.statusCode;
    }
    if (error is SocketException) {
      return 601;
    }
    return 900;
  }

  static String getNewId() {
    return "${DateTime.now().millisecondsSinceEpoch.toInt()}";
  }

  void reloadQueue(String id) {
    try {
      //temukan id antrian
      QueueModel queueModel = queue.firstWhere((element) => element.id == id);

      //set status kembali ke pending
      queueModel.status = 'pending';

      //rename file name
      String fileName =
          '${queueModel.id}#${queueModel.name}#${queueModel.createdDate!.toIso8601String().replaceAll(':', '_').replaceAll('.', '--')}##${queueModel.status}.json';
      File(queueModel.filePath ?? "")
          .renameSync('${directory!.path}/$fileName');

      //update file path
      queueModel.filePath = '${directory!.path}/$fileName';

      //notify ke controller
      queueController.add(queue);
    } catch (e) {
      //
    }
  }

  void deleteQueue(String id) {
    try {
      //temukan id pada antrian
      QueueModel queueModel = queue.firstWhere((element) => element.id == id);

      //delete file
      File(queueModel.filePath ?? "").deleteSync();

      //delete data yang ditemukan dari antrian
      queue.remove(queueModel);

      //notify ke controller
      queueController.add(queue);
    } catch (e) {
      //
    }
  }
}

enum QueueStatus { idle, running }
