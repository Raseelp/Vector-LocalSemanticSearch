import 'package:flutter/material.dart';
import 'package:twentyonevision/models/collection_model.dart';

// Built-ins live in code, not the database - the DB only holds which of
// them a user has hidden - so improving a prompt list in an app update
// reaches everyone without overwriting anything they've changed.
//
// Each has several phrasings averaged together (see SmartCollection.prompts).
// `sensitivity` is the per-collection z-score cutoff; these are starting
// points to tune against a real library: broad, unmistakable subjects
// (beach, pets) can run a little stricter, vaguer moods a little looser.
const List<SmartCollection> defaultCollections = [
  SmartCollection(
    id: 'builtin_pets',
    name: 'Pets',
    icon: Icons.pets_rounded,
    explainQuery: 'pet',
    prompts: ['a photo of a pet', 'a dog', 'a cat', 'a cute animal at home'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_flowers',
    name: 'Flowers',
    icon: Icons.local_florist_outlined,
    explainQuery: 'flowers',
    prompts: ['a photo of flowers', 'a blooming flower', 'a bouquet of flowers', 'a flower garden'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_beach',
    name: 'Beach',
    icon: Icons.beach_access_outlined,
    explainQuery: 'beach',
    prompts: ['a photo of a beach', 'sand and ocean waves', 'a tropical beach', 'people at the seaside'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_food',
    name: 'Food',
    icon: Icons.restaurant_outlined,
    explainQuery: 'food',
    prompts: ['a photo of food', 'a plate of delicious food', 'a meal on a table', 'a restaurant dish'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_documents',
    name: 'Documents',
    icon: Icons.description_outlined,
    explainQuery: 'document',
    prompts: ['a photo of a document', 'a page of printed text', 'a receipt', 'a scanned paper'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_screenshots',
    name: 'Screenshots',
    icon: Icons.smartphone_outlined,
    explainQuery: 'screenshot',
    prompts: ['a screenshot of a phone screen', 'a screenshot of an app', 'a chat conversation screenshot'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_selfies',
    name: 'Selfies',
    icon: Icons.face_outlined,
    explainQuery: 'selfie',
    prompts: ['a selfie', 'a close-up photo of a person smiling at the camera', 'a mirror selfie'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_collage',
    name: 'Collage',
    icon: Icons.collections_outlined,
    explainQuery: 'collage',
    prompts: ['a collage of photos', 'a photo grid of several pictures', 'a photo collage with multiple images'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_golden_hour',
    name: 'Golden hour',
    icon: Icons.wb_twilight_outlined,
    explainQuery: 'golden hour',
    prompts: ['golden hour light', 'warm sunset glow', 'a photo taken at golden hour', 'long orange shadows at sunset'],
    isBuiltIn: true,
    sensitivity: 2.8,
  ),
  SmartCollection(
    id: 'builtin_neon_night',
    name: 'Neon night',
    icon: Icons.nightlife_outlined,
    explainQuery: 'neon night',
    prompts: ['neon lights at night', 'a city street at night with glowing signs', 'colorful neon glow in the dark'],
    isBuiltIn: true,
    sensitivity: 2.8,
  ),
  SmartCollection(
    id: 'builtin_cozy',
    name: 'Cozy',
    icon: Icons.weekend_outlined,
    explainQuery: 'cozy',
    prompts: ['a cozy warm room', 'a blanket and a hot drink', 'candlelight and soft warm lighting', 'a snug reading corner'],
    isBuiltIn: true,
    sensitivity: 2.8,
  ),
  SmartCollection(
    id: 'builtin_minimal',
    name: 'Minimal',
    icon: Icons.crop_square_outlined,
    explainQuery: 'minimal',
    prompts: ['a minimalist photo', 'a simple composition with lots of empty space', 'clean minimal design'],
    isBuiltIn: true,
    sensitivity: 2.8,
  ),
  SmartCollection(
    id: 'builtin_rainy',
    name: 'Rainy',
    icon: Icons.water_drop_outlined,
    explainQuery: 'rain',
    prompts: ['a rainy day', 'raindrops on a window', 'wet streets in the rain', 'a grey rainy sky'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
  SmartCollection(
    id: 'builtin_road_trip',
    name: 'Road trip',
    icon: Icons.directions_car_outlined,
    explainQuery: 'road trip',
    prompts: ['a road trip', 'a view from a car window on a highway', 'an open road through the countryside', 'a scenic drive'],
    isBuiltIn: true,
    sensitivity: 3.0,
  ),
];
