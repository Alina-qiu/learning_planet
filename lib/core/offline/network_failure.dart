import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Business, authorization and database errors must never become offline success.
bool isNetworkFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is HttpException ||
    error is http.ClientException ||
    error is AuthRetryableFetchException ||
    (error is PostgrestException &&
        const {
          '500',
          '502',
          '503',
          '504',
          'PGRST000',
          'PGRST001',
          'PGRST002',
        }.contains(error.code));
