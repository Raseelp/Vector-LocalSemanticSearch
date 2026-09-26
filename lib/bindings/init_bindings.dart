import 'package:get/get.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';

class InitBindings extends Bindings {
  @override
  void dependencies() {
    Get.put(NativeController());
    Get.put(CollectionsController());
    Get.put(FacesController());
  }
}
