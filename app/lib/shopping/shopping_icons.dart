import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The line icons of the shopping articles, drawn on 24 × 24 like Material icons.
///
/// Each one is SVG path data, plus two shorthands of our own: `O cx cy r` is a circle and
/// `R x y w h r` a rectangle with round corners. A line of no length is drawn as a dot.
const shoppingIcons = <String, String>{
  // --- Obst ---
  'apple':
      'M12 7.5c-1.5-1-4.5-1.2-6 .8-1.8 2.4-.8 7 1.2 9.5 1.3 1.6 2.8 2.4 4.8 1.4 2 1 3.5.2 4.8-1.4 2-2.5 3-7.1 1.2-9.5-1.5-2-4.5-1.8-6-.8z'
      'M12 7.5c0-2 .8-3.5 2.5-4.3 M12.8 5.4c1.3-1 2.9-1 3.9-.1-1.1 1-2.6 1.1-3.9.1z',
  'pear':
      'M12 6.5c-1.5 0-2.3 1.2-2.6 3-.3 1.6-2.9 3.3-2.9 6.3 0 3.1 2.5 4.7 5.5 4.7s5.5-1.6 5.5-4.7c0-3-2.6-4.7-2.9-6.3-.3-1.8-1.1-3-2.6-3z'
      'M12 6.5c0-1.4.4-2.6 1.2-3.4 M13 4.6c1-.9 2.4-1 3.4-.4-.8 1-2.2 1.2-3.4.4z',
  'banana':
      'M5 7c-.5 6 3.5 11 10 11.5 2 .2 3.6-.3 4.5-1.2-.3-.6-1.2-.8-2.2-.7C11.5 17 7.6 13 7 6.8c-.1-.8-.6-1.2-1.2-1.2-.5.2-.8.7-.8 1.4z'
      'M5.6 5.7 5 4',
  'citrus': 'O12 13 7.5 M12 5.5c.3-1.6 1.6-2.5 3.2-2.3-.3 1.6-1.6 2.5-3.2 2.3z M9 11.5h.01 M14.5 15h.01',
  'lemon': 'M4 12c0-3.3 3.6-6 8-6s8 2.7 8 6-3.6 6-8 6-8-2.7-8-6z M4 12H2.8 M20 12h1.2 M8 10.5c1-1 2.3-1.5 3.5-1.5',
  'grapes':
      'O9 9.5 2 O13 9.5 2 O7 13 2 O11 13 2 O15 13 2 O9 16.5 2 O13 16.5 2 O11 20 1.8 M11 7.5V3.5 M11 5c1.5-1.5 3.5-1.5 5-.5',
  'cherries': 'O7.5 17 3 O16 16 3 M7.5 14c.5-4 2.5-7.5 6.5-10 M16 13c-.4-3.5-1-6.5-2-9 M14 4c1.5-.6 3.2-.4 4.5.5',
  'strawberry':
      'M12 8c-3.5 0-6.5 1.5-6.5 4.5 0 3.5 3.5 7.5 6.5 9 3-1.5 6.5-5.5 6.5-9C18.5 9.5 15.5 8 12 8z M8.5 8.3 9 5.5l3 2 3-2 .5 2.8 M12 7.5V4'
      'M10 12h.01 M14 12h.01 M12 15h.01 M9.5 15.5h.01 M14.5 15.5h.01',
  'berries': 'O8.5 15.5 3.5 O15.5 15.5 3.5 O12 9.5 3.5 M12 6V3.5 M12 4.5c1-1 2.5-1.2 3.5-.5',
  'pineapple':
      'M7 14.5c0-3.3 2.2-5.5 5-5.5s5 2.2 5 5.5-2.2 6.5-5 6.5-5-3.2-5-6.5z M8.5 12.5l6 6 M15.5 12.5l-6 6 M12 9V3 M12 8.5 9 4.5 M12 8.5l3-4'
      'M12 9 8 7.5 M12 9l4-1.5',
  'melon': 'M3 9h18A9 9 0 0 1 3 9z M5.5 9a6.5 6.5 0 0 0 13 0 M9 12h.01 M12 13.5h.01 M15 12h.01',
  'peach': 'O12 13.5 7 M12 6.5c-1 2-1 5 0 7 M12 6.5c1-2 3-3 5-2.5-.8 1.7-3 2.6-5 2.5z',
  'kiwi': 'O12 12 8 O12 12 3 M12 6.5v1 M12 16.5v1 M6.5 12h1 M16.5 12h1 M8.2 8.2l.7.7 M15.1 15.1l.7.7 M15.8 8.2l-.7.7 M8.9 15.1l-.7.7',
  'mango': 'M6 15c-1.5-4.5 1.5-10 7-10 4 0 6 3 5 7-1 4.5-5.5 8-9 7-1.5-.3-2.5-2-3-4z M13 5c.5-1.3 1.5-2 3-2 M9 10c1-1.5 2.5-2.3 4-2.5',
  'avocado': 'M12 3c-2.5 0-4 3-4.5 6-.5 2.5-2.5 4-2.5 7a7 7 0 0 0 14 0c0-3-2-4.5-2.5-7C16 6 14.5 3 12 3z O12 15.5 2.5',
  // --- Gemüse ---
  'carrot':
      'M15 9c-2-2-4.5-1.5-6 0-2 2-4 8-5 11 3-1 9-3 11-5 1.5-1.5 2-4 0-6z M15 9c.5-2 2-3.5 4-3.5 M15 9c2 .2 3.5-.5 4.5-2 M15 9l1-4.5'
      'M8 13l1.5 1.5 M10.5 10.5 12 12 M6.5 17 8 18.5',
  'potato': 'M5 12c0-4 3-6.5 7-6.5s7.5 2 7.5 5.5-3.5 7.5-8.5 7.5S5 16 5 12z M9 10h.01 M14 9.5h.01 M12 14h.01 M15.5 13.5h.01',
  'tomato': 'O12 13.5 7 M12 6.5V3.5 M8.5 7.5 12 6.5l3.5 1 M10 9.5 12 6.5l2 3',
  'cucumber': 'M5.5 18.5c-1.5-1.5-1-4 1-6l6-6c2-2 4.5-2.5 6-1s1 4-1 6l-6 6c-2 2-4.5 2.5-6 1z M9 15h.01 M12 12h.01 M15 9h.01 M11 16h.01 M14 13h.01',
  'pepper':
      'M12 7c-2-1-5.5-.5-6.5 2.5-.8 2.7 0 7 1.5 9.5 1 1.7 2.7 2.2 4 1.2.6-.4 1.4-.4 2 0 1.3 1 3 .5 4-1.2 1.5-2.5 2.3-6.8 1.5-9.5C17.5 6.5 14 6 12 7z'
      'M12 7V5.5c0-1 .7-2 2-2.5 M12 7.5c-.5 3-.5 8 0 12',
  'chili': 'M5 19c5 0 10-3 12-9 .4-1.3-.4-2.5-1.7-2.5H14c-1 0-1.5.8-2 1.5C10 12 7.5 15.5 5 19z M15.5 7.5c0-1.5.8-3 2.5-3.5',
  'broccoli': 'M9.5 14v6.5h5V14 M7.5 14a3 3 0 0 1-.5-6 4 4 0 0 1 7.5-2 3.5 3.5 0 0 1 2.5 8z M12 14v3 M10 9.5h.01 M14 9h.01 M12 11h.01',
  'salad':
      'M12 20c-4.5 0-8-3-8-7.5 0-2 1-3.5 2.5-4.5C7 5.5 9.3 4 12 4s5 1.5 5.5 4c1.5 1 2.5 2.5 2.5 4.5 0 4.5-3.5 7.5-8 7.5z M12 20V9 M12 15l-3-3 M12 12.5l3-3',
  'onion':
      'M12 4c0 2-1 3-3 4.5S5 12 5 15a7 7 0 0 0 14 0c0-3-2-5-4-6.5S12 6 12 4z M12 4V2.5 M9.5 11c-1 1.5-1.5 3-1 5.5 M14.5 11c1 1.5 1.5 3 1 5.5'
      'M12 9.5v9',
  'garlic':
      'M12 4c0 2.5-2 3.5-4 5-2 1.6-3 3.5-3 5.5 0 3 3 5.5 7 5.5s7-2.5 7-5.5c0-2-1-3.9-3-5.5-2-1.5-4-2.5-4-5z M12 4V2.5'
      'M12 9.5c-1.5 2-2 6-1.5 10 M12 9.5c1.5 2 2 6 1.5 10',
  'leek': 'M4.5 19.5 13 11 M7 21.5l8-8 M4.5 19.5c.3 1.1 1.2 1.8 2.5 2 M13 11l3-7.5 M15 13l6-4 M14 12l4.5-6',
  'mushroom': 'M4 12a8 7 0 0 1 16 0z M9.5 12v6.5a2.5 2.5 0 0 0 5 0V12 M9 8.5h.01 M14 7.5h.01',
  'corn':
      'M12 3c-2.5 0-4 4-4 9s1.5 8 4 8 4-3 4-8-1.5-9-4-9z M8.3 9h7.4 M8 13h8 M8.5 17h7 M12 3v17 M8 15c-2-1-3.5-3-4-5 1.5 1 3 2 4 2'
      'M16 15c2-1 3.5-3 4-5-1.5 1-3 2-4 2',
  'eggplant': 'M15 6c-3 0-4 2-5.5 4S5 13 5 16.5 7.5 21 10 21c4 0 6-4 7-8 .8-3.2.5-7-2-7z M15 6c.5-1.5 1.5-2.5 3-3 M12.5 7c1-.8 3-1 4.5 0',
  'pumpkin':
      'M12 7c-1.5-1-5-1-6.5 1.5S4 15.5 6 18c1.3 1.6 3.5 2 6 1 2.5 1 4.7.6 6-1 2-2.5 2-7.5.5-9.5S13.5 6 12 7z M12 7v12'
      'M8.5 7.3C7.5 10 7.5 15 9 19 M15.5 7.3c1 2.7 1 7.7-.5 11.7 M12 7c0-1.5.5-3 2-3.5',
  'herbs':
      'M12 21V5 M12 9.5c-2.5 0-4-1.5-4.5-4 2.5 0 4 1.5 4.5 4z M12 9.5c2.5 0 4-1.5 4.5-4-2.5 0-4 1.5-4.5 4z M12 15c-2.5 0-4-1.5-4.5-4 2.5 0 4 1.5 4.5 4z'
      'M12 15c2.5 0 4-1.5 4.5-4-2.5 0-4 1.5-4.5 4z M12 5c-.3-1 0-2 .5-2.5',
  'peas': 'M3.5 15c3-1 7-4 9-7 1.5-2 4-3.5 7.5-3-1 5-4 9-8 11.5-3 1.8-6.5 1.5-8.5-1.5z O8.5 14 1.3 O11.8 11.7 1.3 O14.8 8.7 1.3 M20 5l1.5-1.5',
  'radish': 'O12 14.5 5 M12 19.5V22 M12 9.5V6.5 M12 7 9 3.5 M12 7l3-3.5 M12 7V3',
  'asparagus': 'M8.5 21V9.5 M12 21V6.5 M15.5 21V9.5 M7.5 10l1-3.5 1 3.5 M11 7l1-3.5 1 3.5 M14.5 10l1-3.5 1 3.5 M7 17h10',
  'root':
      'M5 14c1-2 3-2 4-1 1-2 3-3 5-2 1-1.5 3-2 4.5-.5 1 1 1 2.5 0 3.5 1 1 .5 3-1 3.5-1.5.5-3 0-4-1-1.5 1.5-4 1.5-5.5.5-1.5 1-3 .5-3-3z'
      'M9 13l-1-2.5 M14 11l.5-2.5',
  // --- Brot & Gebäck ---
  'bread':
      'M5 11c-1.5-.5-2-2-1.5-3.5C4.2 5.6 7 4.5 12 4.5s7.8 1.1 8.5 3c.5 1.5 0 3-1.5 3.5V19a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1z M5 11h1.5 M17.5 11H19',
  'baguette':
      'M4.5 19.5c-1-1-1-3 .5-4.5L15 5c1.5-1.5 3.5-1.5 4.5-.5s1 3-.5 4.5L9 19c-1.5 1.5-3.5 1.5-4.5.5z M8 13l2.5 1.5 M11 10l2.5 1.5 M14 7l2.5 1.5',
  'roll': 'M3.5 14c0-4.5 3.8-8 8.5-8s8.5 3.5 8.5 8c0 2.5-2 4-4 4h-9c-2 0-4-1.5-4-4z M12 6.5c-1.2 2.5-1.2 5 0 7.5',
  'croissant':
      'M12 7c2.5 0 4 1.5 4.5 4l-2.5 4h-4l-2.5-4c.5-2.5 2-4 4.5-4z M7.5 11 4 12.5c-.8.4-1 1.4-.4 2l2.4 2 4-1.5 M16.5 11l3.5 1.5c.8.4 1 1.4.4 2L18 16.5 14 15',
  'pretzel': 'M12 13c-3 3-7 4-8 1.5S5 7 8.5 6.5c2-.3 3.5 1.5 3.5 4 0-2.5 1.5-4.3 3.5-4C19 7 21 12 20 14.5S15 16 12 13z M7.5 18.5 12 13l4.5 5.5',
  'cake':
      'M4 20.5h16 M5 20.5V13h14v7.5 M5 15.5c1.2 1 2.3 1 3.5 0s2.3-1 3.5 0 2.3 1 3.5 0 2.3-1 3.5 0 M12 13V9.5 M12 7.5c-.8-.7-.8-1.7 0-2.8.8 1.1.8 2.1 0 2.8z',
  'cupcake':
      'M6.5 13h11l-1.5 7.5H8z M5.5 13c-.5-3 1.5-5.5 4-5.5.5-2 1.5-3 2.5-3s2 1 2.5 3c2.5 0 4.5 2.5 4 5.5 M10.3 13l.4 7.5 M13.7 13l-.4 7.5',
  'cookie': 'O12 12 8 M9 9h.01 M14 8h.01 M15.5 13h.01 M10 14h.01 M12.5 17h.01 M8 17h.01',
  'waffle': 'R4 4 16 16 2 M4 9.3h16 M4 14.7h16 M9.3 4v16 M14.7 4v16',
  // --- Milch & Käse ---
  'milk': 'M7.5 9 10 5h4l2.5 4v11.5h-9z M7.5 9h9 M10 5V2.5h4V5 M10 13h4v3.5h-4z',
  'cheese': 'M3 18v-6l11-7 7 7v6z M3 12h18 O8 15.2 1.2 O15 15.5 1.5 O12 9 .9',
  'egg': 'M12 3c-3.5 0-6.5 5.5-6.5 10.5S8.5 21 12 21s6.5-2.5 6.5-7.5S15.5 3 12 3z M9 11c.3-1.5 1-2.8 2-3.5',
  'butter': 'M3 11h14v6H3z M3 11l4-3h14l-4 3 M21 8v6l-4 3 M6 14h5',
  'cup': 'M5 7.5h14 M6.2 7.5l1.3 12.5h9l1.3-12.5 M5.5 4.5h13v3h-13z M7 12h10',
  'cube': 'M4 8l8-4 8 4v8l-8 4-8-4z M4 8l8 4 8-4 M12 12v8',
  // --- Fleisch & Fisch ---
  'fish': 'M6 12c2.5-3.5 6-5 9.5-4.5 2.5.4 4.3 2 5 4.5-.7 2.5-2.5 4.1-5 4.5-3.5.5-7-1-9.5-4.5z M6 12 2.5 8.5v7z M17 11h.01 M12 9.5c.7 1.6.7 3.4 0 5',
  'shrimp':
      'M17 6c-5 0-10 3-10 8 0 3 2 5 5 5h2 M7 14c-1.5 0-3 1-3.5 3 1.5.5 3 0 3.5-1 M17 6c2 0 3 1 3 2.5S19 11 17 11c-3 0-6 2-6 5'
      'M17 6l2.5-3 M17 6l4-1.5 M10 9.5l1.5 2 M13 7.5l1 2.2',
  'shell': 'M12 20 3.5 10c2-4 5-6 8.5-6s6.5 2 8.5 6z M12 20 7.5 6.5 M12 20V4 M12 20l4.5-13.5 M9.5 20.5h5',
  'meat': 'M5.5 8.5C8 4.5 14 3.5 18 5.5s3.5 7 0 10-7.5 5-11 4.5S3 12.5 5.5 8.5z O15 10 2.2',
  'drumstick':
      'M10.5 13.5c-1.5-1.5-2-3.5-1.5-5.5.8-3 3.8-5 7-4.5s5.5 3.5 4.5 7-4.5 5-7.5 4.5c-1-.2-1.8-.7-2.5-1.5z M10.5 13.5 7 17 O5.4 16.6 1.1 O7.4 18.6 1.1',
  'sausage': 'M6.5 19.5a3 3 0 0 1-2.1-5.1l9.9-9.9a3 3 0 0 1 4.2 4.2l-9.9 9.9a3 3 0 0 1-2.1.9z M18.4 4.5 20 2.9 M5 19l-1.6 1.6 M9 13l1 1 M12 10l1 1',
  'bacon':
      'M5 6h14a1 1 0 0 1 1 1v.5c0 1-1 1.5-1 2.5s1 1.5 1 2.5-1 1.5-1 2.5 1 1.5 1 2.5v.5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-.5c0-1 1-1.5 1-2.5s-1-1.5-1-2.5 1-1.5 1-2.5-1-1.5-1-2.5V7a1 1 0 0 1 1-1z'
      'M8 9.5c2 1 6 1 8 0 M8 14.5c2 1 6 1 8 0',
  // --- Gewürze & Zutaten ---
  'shaker': 'M7.5 21l1-10h7l1 10z M8.5 11c0-3 1-6 3.5-6s3.5 3 3.5 6 M11 7.5h.01 M13 7.5h.01 M12 9h.01',
  'oil': 'M10 3h4v3l2 3v11a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V9l2-3z M8 13h8 M10 6h4 M10.5 16.5c.5-1 1-1.5 1.5-2.5.5 1 1 1.5 1.5 2.5a1.5 1.5 0 0 1-3 0z',
  'sauce': 'M10 2.5h4l.5 2.5h-5z M9.5 5h5c1.5 2 2.5 4 2.5 6.5V20a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1v-8.5C7 9 8 7 9.5 5z M7 14h10 M7 17.5h10',
  'jar': 'R6 7 12 14 2 M7 3.5h10V7H7z M6 12h12 M6 17h12',
  'can': 'M6 5.5C6 4.1 8.7 3 12 3s6 1.1 6 2.5v13c0 1.4-2.7 2.5-6 2.5s-6-1.1-6-2.5z M6 5.5C6 6.9 8.7 8 12 8s6-1.1 6-2.5 M6 10c0 1.4 2.7 2.5 6 2.5s6-1.1 6-2.5 M6 15c0 1.4 2.7 2.5 6 2.5s6-1.1 6-2.5',
  'sack': 'M7 6c-.5 4-2 6-2 10 0 3 2 5 7 5s7-2 7-5c0-4-1.5-6-2-10 M7 6c1.5.8 3 1 5 1s3.5-.2 5-1 M7 6 6 3.5l3 1 3-1.5 3 1.5 3-1L17 6 M9.5 14h5',
  'nut': 'M12 3c-4 0-7 3.5-7 9s3 9 7 9 7-3.5 7-9-3-9-7-9z M12 3v18 M8.5 8c1.5 1 1.5 2.5 0 3.5s-1.5 2.5 0 3.5 M15.5 8c-1.5 1-1.5 2.5 0 3.5s1.5 2.5 0 3.5',
  'olive': 'O9 15.5 4 O16 12.5 3.5 M9 11.5c0-3 1.5-6 4-8.5 M16 9c-.5-2.5-1.5-4.5-3-6 M13 3c2 0 4 1 5 2.5',
  'tube': 'M8 21h8l-1-15H9z M9 6V3.5h6V6 M8.5 17h7 M10 9.5h4',
  // --- Fertig- & Tiefkühlprodukte ---
  'pizza': 'M12 21 3.5 6.5c5.3-3 11.7-3 17 0z M5 9c4.5-2.2 9.5-2.2 14 0 O10 11.5 1.2 O14 12.5 1 O12 16 1',
  'snowflake': 'M12 3v18 M4.2 7.5l15.6 9 M19.8 7.5l-15.6 9 M9.5 4.5 12 6l2.5-1.5 M9.5 19.5 12 18l2.5 1.5 M4.5 10.5l2.5-1.5 0-2.5 M19.5 13.5 17 15v2.5',
  'icecream': 'M7 10a5 5 0 0 1 10 0z M7.5 10 12 21l4.5-11 M10 13.5l4 1.5 M9 11l5.5 2',
  'fries': 'M6 11h12l-1.5 10h-9z M8 11 7 4 M10.5 11V3 M13.5 11 14 3.5 M16 11l1.5-6 M6 11c2 2 10 2 12 0',
  'takeaway': 'M4 8h16l-2 12.5H6z M7 8l2-4h6l2 4 M12 4v4 M9 13h6',
  'soup': 'M3.5 11h17c0 4.5-3.8 8-8.5 8s-8.5-3.5-8.5-8z M9 8c-.8-1 .8-2 0-3.5 M12 8c-.8-1 .8-2 0-3.5 M15 8c-.8-1 .8-2 0-3.5 M9 21h6',
  'dish': 'M3 10h18v6a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3z M3 10 1.5 8.5 M21 10l1.5-1.5 M6 13h12 M6 16h12',
  // --- Getreideprodukte ---
  'pasta': 'M3 12h18a9 8 0 0 1-18 0z M6 12c0-2 1.5-3 3-3s3 1.5 2 3 M11 12c0-2.5 1.5-3.5 3-3.5s2.5 2 1.5 3.5 M17 4l-3 6.5 M20 5l-4 6',
  'rice': 'M3 12h18a9 8 0 0 1-18 0z M5 12c.5-3 3.5-5 7-5s6.5 2 7 5 M15 2.5 12.5 7 M18.5 3.5l-3.5 4 M9 10h.01 M12 9.5h.01 M15 10h.01',
  'cereal': 'M3 12h18a9 8 0 0 1-18 0z M6.5 12l1-2 2 1 M11 12l1.5-2.5 2 1.5 M16 12l1.5-1.5 M14 4l7 6',
  'bar': 'R4 8.5 16 7 1.5 M4 9.5 2 8v8l2-1.5 M20 9.5 22 8v8l-2-1.5 M8 12h8',
  // --- Süßwaren & Snacks ---
  'chocolate': 'R5 3 14 18 1.5 M5 9h14 M5 15h14 M12 3v18',
  'candy': 'O12 12 4 M8.5 10 4 7v10l4.5-3 M15.5 10 20 7v10l-4.5-3 M10.5 10.5l3 3',
  'chips': 'M6 3h12l-1 3 1 12-1 3H7l-1-3 1-12z M7 6h10 M7 18h10 O12 12 2.5',
  'popcorn': 'M6 9l2 12h8l2-12z M10 9l.5 12 M14 9l-.5 12 M6 9c-1.5-2 0-4.5 2-4 .5-2 3-2.5 4-1 1-1.5 3.5-1 4 1 2-.5 3.5 2 2 4',
  // --- Getränke ---
  'water': 'M10 2.5h4v2c2 1 3 2.5 3 4.5v11a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 7 20V9c0-2 1-3.5 3-4.5z M7 12h10 M7 16h10',
  'juice': 'M6 4h12l-1.5 16a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1z M6.8 11h10.4 M12.5 11 15.5 1.5',
  'beer':
      'M5 8h10v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z M15 10.5h2a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2h-2 M5 8c-1-2 .5-4 2.5-3.5C8.5 3 11 3 12 4.5c1.5-1 3.5 0 3 3.5'
      'M8.5 11v7 M11.5 11v7',
  'wine': 'M8 3h8l.5 5a4.5 4.5 0 0 1-9 0z M12 12.5V20 M8.5 20.5h7 M7.8 7h8.4',
  'flute': 'M10 3h4l.5 7a2.5 2.5 0 0 1-5 0z M12 12.5V20 M9.5 20.5h5 M9.8 6.5h4.4 M17 4h.01 M18.5 6.5h.01 M16.5 8h.01',
  'liquor': 'M10 2.5h4V7c1.8.8 3 2.2 3 4.5V20a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1v-8.5C7 9.2 8.2 7.8 10 7z M7 13h10v4H7z',
  'soda':
      'M7 5c0-1 .5-1.5 1.5-2h7c1 .5 1.5 1 1.5 2v14c0 1-.5 1.5-1.5 2h-7c-1-.5-1.5-1-1.5-2z M7 6.5h10 M7 17.5h10 M7 13c2-2 4 1.5 6-.5s3-1 4-.5'
      'M11 4.8h2',
  'coffee': 'M4 9h12v6a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5z M16 11h1.5a2.5 2.5 0 0 1 0 5H16 M8 3c-.8 1 .8 2 0 3.5 M12 3c-.8 1 .8 2 0 3.5',
  'tea': 'M4 9h12v6a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5z M16 11h1.5a2.5 2.5 0 0 1 0 5H16 M10 9V4.5 M10 4.5l3 1.5v3',
  'cigarette': 'M2 14h15v3H2z M17 14h2.5v3H17 M21.5 14v3 M17 11c0-1.5 1-1.5 1-3s-1-1.5-1-3 M20 11c0-1.5 1-1.5 1-3',
  // --- Haushalt ---
  'paper': 'M7 5h10c1.7 0 3 1.8 3 4s-1.3 4-3 4H7 M7 5c-1.7 0-3 1.8-3 4s1.3 4 3 4 3-1.8 3-4-1.3-4-3-4z O7 9 1 M17 13v7H9v-2.5 M20 9v7',
  'spray': 'M9 9h6l1 3v8a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1v-8z M10 9V6h4v3 M10 6V4h5l2 1.5 M19 5.5h1.5 M19 3.5l1-.5 M19 7.5l1 .5 M8.5 15h7',
  'detergent': 'M7 7h10v13a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1z M10 7V4h4v3 M17 9h1.5a1.5 1.5 0 0 1 1.5 1.5v4a1.5 1.5 0 0 1-1.5 1.5H17 M10 12h4v4h-4z',
  'tab': 'M4 9l8-4 8 4v6l-8 4-8-4z M4 9l8 4 8-4 M12 13v6 O12 9 1.5',
  'sponge': 'R3 8 18 9 2 M3 12h18 M7 15h.01 M11 14.5h.01 M15 15h.01 M18 14.5h.01',
  'trashbag': 'M7 8c-2 3-3 6-3 9 0 2.5 2 4 8 4s8-1.5 8-4c0-3-1-6-3-9z M7 8h10 M9 8l-1-4 4 2 4-2-1 4',
  'foil': 'M3 10l3-3h15l-3 3z M3 10h15v6H3z M18 10l3-3v6l-3 3 M6 13h9',
  'battery': 'R3 8 16 8 1.5 M21 10.5v3 M6.5 12h3 M8 10.5v3 M13 12h3',
  'bulb': 'M9.5 18h5 M10.5 21h3 M12 3a6 6 0 0 0-3.5 10.9c.6.4.9 1 1 1.7l.1 2.4h4.8l.1-2.4c.1-.7.4-1.3 1-1.7A6 6 0 0 0 12 3z',
  'candle': 'R9 10 6 11 1 M12 10V8 M12 6.5c-1-1-1-2.2 0-3.5 1 1.3 1 2.5 0 3.5z M9 13.5h6',
  'matches': 'R3 13 18 7 1 M3 15.5h18 M12 13l4.5-8.5 O17 3.8 1.3',
  'gift':
      'R3 8 18 4 1 M5 12v8a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-8 M12 8v13 M12 8c-2 0-4.5-1-4.5-2.5S9 3 10 3.5c1 .5 2 2.5 2 4.5z'
      'M12 8c2 0 4.5-1 4.5-2.5S15 3 14 3.5c-1 .5-2 2.5-2 4.5z',
  'tissue': 'M4 11h16v9H4z M4 11l2-3h12l2 3 M9.5 11c0-2 1-4 2.5-5.5 1.5 1.5 2.5 3.5 2.5 5.5',
  'straw': 'M8 21h8l1-10H7z M12 11l2.5-8.5H18',
  'pot': 'M4 10h16v7a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3z M2 10h20 M6 10c0-2 2.5-3 6-3s6 1 6 3 M11 5h2',
  // --- Pflege & Gesundheit ---
  'tooth':
      'M7 3c-2 0-3.5 1.5-3.5 4 0 3 1.5 5 2 8 .4 2.5 1 6 2.5 6s1.8-3 2.3-5c.3-1 .6-1.5 1.2-1.5s.9.5 1.2 1.5c.5 2 .8 5 2.3 5s2.1-3.5 2.5-6c.5-3 2-5 2-8'
      'M20.5 7c0-2.5-1.5-4-3.5-4s-3 1-5 1-3-1-5-1z',
  'pump': 'M8 10h8v10a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1z M10.5 10V7h3v3 M12 7V4.5h4 M16 4.5v1.5 M8 14h8',
  'cream': 'R4 11 16 9 2 R5 7 14 4 1 M4 15h16',
  'sun': 'O12 12 4 M12 2v2 M12 20v2 M2 12h2 M20 12h2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4',
  'razor': 'R5 4 14 4 1 M12 8v12 M10.5 20.5h3 M8 6h8',
  'pill': 'M10.5 20.5a5 5 0 0 1-7-7l6-6a5 5 0 0 1 7 7z M8.5 10.5l5 5',
  'bandage':
      'M3.5 13.5 13.5 3.5a3 3 0 0 1 4.2 0l2.8 2.8a3 3 0 0 1 0 4.2l-10 10a3 3 0 0 1-4.2 0l-2.8-2.8a3 3 0 0 1 0-4.2z M9 9l6 6'
      'M11 12h.01 M12 11h.01 M13 12h.01 M12 13h.01',
  'babybottle': 'M9 8h6v12a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1z M9.5 8V6.5h5V8 M10.5 6.5 11 3.5h2l.5 3 M9 12h2 M9 15h2',
  'diaper': 'M3 7h18v3c0 5-4 9-9 9s-9-4-9-9z M3 10c2.5 0 4.5 2 5 4.5 M21 10c-2.5 0-4.5 2-5 4.5',
  'nailpolish': 'R7.5 11 9 10 2 M10 11V8h4v3 M11 8V3h2v5',
  'swab': 'M7.5 16.5l9-9 O5.5 18.5 2.3 O18.5 5.5 2.3',
  'drop': 'M12 3c3.5 4.5 6 8 6 11a6 6 0 0 1-12 0c0-3 2.5-6.5 6-11z M9 14.5c0 1.5 1 2.5 2.5 2.8',
  'heart': 'M12 19.5C6 15.5 3.5 12.5 3.5 9.5A4.5 4.5 0 0 1 12 7.5a4.5 4.5 0 0 1 8.5 2c0 3-2.5 6-8.5 10z',
  'spraycan': 'R8 8 8 13 1.5 M9.5 8V5.5h5V8 M11 5.5v-2h2.5 M16 3.5h1.5 M18 2.5l1-.5 M18 4.5l1 .5 M8 12h8',
  // --- Tierbedarf ---
  'paw': 'O6.5 10.5 1.8 O9.5 6 1.8 O14.5 6 1.8 O17.5 10.5 1.8 M12 11c-2.5 0-5 3.5-5 6 0 1.5 1.2 2.5 2.5 2.2 1-.2 1.6-.7 2.5-.7s1.5.5 2.5.7c1.3.3 2.5-.7 2.5-2.2 0-2.5-2.5-6-5-6z',
  'bone': 'M8 16l8-8 M8 16a2.2 2.2 0 1 1-3 1 2.2 2.2 0 1 1 1-3 M16 8a2.2 2.2 0 1 1 3-1 2.2 2.2 0 1 1-1 3',
  'bird': 'M4 14c0-4 3-7 7-7 2 0 3 .5 4 1.5L19.5 7 17 10.5c.5 1 .5 2 .5 3 0 4-3 6.5-7.5 6.5H3.5l3-3c-1.5-1-2.5-2-2.5-3z M14 10h.01 M9 14c1.5 1 3.5 1 5 0',
  // --- Baumarkt & Garten ---
  'flower':
      'O12 8 2 O12 4.3 1.7 O15.5 7 1.7 O14.2 10.9 1.7 O9.8 10.9 1.7 O8.5 7 1.7 M12 12.5V21 M12 18c-2 0-3.5-1-4-3 2 0 3.5 1 4 3z M12 16c2 0 3.5-1 4-3-2 0-3.5 1-4 3z',
  'plant': 'M7 13h10l-1.5 8h-7z M6 13h12 M12 13V7.5 M12 9.5c-2.5 0-4-1.5-4-4 2.5 0 4 1.5 4 4z M12 7.5c0-2.5 1.5-4 4-4 0 2.5-1.5 4-4 4z',
  'wateringcan': 'M5 10h10v9a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1z M15 12.5 19.5 8 21 9 M18.7 7.2l1.6-1.6 M5 12.5H3.5A1.5 1.5 0 0 1 2 11V9 M7.5 10V7.5a2.5 2.5 0 0 1 5 0V10',
  'trowel': 'M12 3v8 M10 3h4 M8 11h8v4.5a4 4 0 0 1-8 0z',
  'mower': 'M3 15h15l1.5-5H6z O6.5 17.5 2 O15.5 17.5 2 M18.5 10l2.5-6.5H22',
  'umbrella': 'M3 11a9 7 0 0 1 18 0z M12 11v10 M12 4V2.5 M9 11c0-3 1-5.5 3-7 2 1.5 3 4 3 7',
  'grill': 'M4 9h16a8 7 0 0 1-16 0z M2.5 9h19 M8.5 15.5 6.5 21 M15.5 15.5l2 5.5 M12 16v5 M8 6c-.8-1 .8-2 0-3 M12 6c-.8-1 .8-2 0-3 M16 6c-.8-1 .8-2 0-3',
  'gas': 'M7 9.5a5 5 0 0 1 10 0V19a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2z M9.5 4.5V2.5h5v2 M7 13h10',
  'screw': 'M9 3h6v3H9z M10 6v11l2 4 2-4V6 M10 8.5l4 1.5 M10 11.5l4 1.5 M10 14.5l4 1.5',
  'brush': 'M11 2h2v8h-2z M9 10h6v3H9z M9 13h6l.5 5c0 1.5-1.5 3-3.5 3s-3.5-1.5-3.5-3z M12 16v5',
};

/// The icon of an article, or its first letter when it has none.
class ArticleIcon extends StatelessWidget {
  const ArticleIcon({super.key, required this.icon, required this.name, this.size = 32, this.color});

  final String icon;
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    final data = shoppingIcons[icon];
    if (data == null) {
      final letter = name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
      return SizedBox.square(
        dimension: size,
        child: Center(
          child: Text(
            letter,
            style: TextStyle(fontSize: size * 0.8, height: 1, fontWeight: FontWeight.w500, color: color),
          ),
        ),
      );
    }
    return CustomPaint(size: Size.square(size), painter: _IconPainter(data, color));
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.data, this.color);

  final String data;
  final Color color;

  static final _cache = <String, Path>{};

  @override
  void paint(Canvas canvas, Size size) {
    final path = _cache[data] ??= parseIconPath(data);
    final scale = size.width / 24;
    canvas.scale(scale);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.data != data || old.color != color;
}

/// Turns the path data of [shoppingIcons] into a [Path].
Path parseIconPath(String data) {
  final path = Path();
  final tokens = RegExp(r'[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)').allMatches(data).map((m) => m.group(0)!).toList();
  var i = 0;
  var command = '';
  var current = Offset.zero;
  var start = Offset.zero;
  Offset? lastControl;
  double next() => double.parse(tokens[i++]);
  bool hasNumber() => i < tokens.length && !RegExp(r'^[A-Za-z]$').hasMatch(tokens[i]);

  while (i < tokens.length) {
    if (!hasNumber()) {
      command = tokens[i++];
    }
    final relative = command == command.toLowerCase() && command != 'O' && command != 'R';
    final base = relative ? current : Offset.zero;
    Offset point() {
      final x = next();
      final y = next();
      return base + Offset(x, y);
    }

    switch (command.toUpperCase()) {
      case 'M':
        current = start = point();
        path.moveTo(current.dx, current.dy);
        // Further pairs after a move are lines.
        command = relative ? 'l' : 'L';
        lastControl = null;
      case 'L':
        current = point();
        path.lineTo(current.dx, current.dy);
        lastControl = null;
      case 'H':
        final x = next();
        current = Offset(relative ? current.dx + x : x, current.dy);
        path.lineTo(current.dx, current.dy);
        lastControl = null;
      case 'V':
        final y = next();
        current = Offset(current.dx, relative ? current.dy + y : y);
        path.lineTo(current.dx, current.dy);
        lastControl = null;
      case 'C':
        final c1 = point();
        final c2 = point();
        final end = point();
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
        lastControl = c2;
        current = end;
      case 'S':
        final c1 = lastControl == null ? current : current * 2 - lastControl;
        final c2 = point();
        final end = point();
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
        lastControl = c2;
        current = end;
      case 'Q':
        final c = point();
        final end = point();
        path.quadraticBezierTo(c.dx, c.dy, end.dx, end.dy);
        lastControl = null;
        current = end;
      case 'A':
        final rx = next();
        final ry = next();
        final rotation = next();
        final large = next() != 0;
        final sweep = next() != 0;
        final end = point();
        path.arcToPoint(
          end,
          radius: Radius.elliptical(rx, ry),
          rotation: rotation,
          largeArc: large,
          clockwise: sweep,
        );
        current = end;
        lastControl = null;
      case 'Z':
        path.close();
        current = start;
        lastControl = null;
      case 'O':
        final center = Offset(next(), next());
        final r = next();
        path.addOval(Rect.fromCircle(center: center, radius: r));
        current = start = center;
        lastControl = null;
      case 'R':
        final x = next();
        final y = next();
        final w = next();
        final h = next();
        final r = next();
        path.addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(math.max(r, 0))));
        current = start = Offset(x, y);
        lastControl = null;
      default:
        throw FormatException('Unbekannter Pfadbefehl $command in $data');
    }
  }
  return path;
}
