import GHC.Unicode
import Data.Ix ( index )

main = do
  print $ UppercaseLetter == UppercaseLetter
  print $ UppercaseLetter == LowercaseLetter
  print $ NonSpacingMark <= MathSymbol
  print $ enumFromTo ModifierLetter SpacingCombiningMark
  print (read "DashPunctuation" :: GeneralCategory)
  print $ show EnclosingMark
  print (minBound :: GeneralCategory)
  print (maxBound :: GeneralCategory)
  print $ index (OtherLetter,Control) FinalQuote
  print $ generalCategory 'a'
  print $ generalCategory 'A'
  print $ generalCategory '0'
  print $ generalCategory '%'
  print $ generalCategory '♥'
  print $ generalCategory '\31'
  print $ generalCategory ' '
  print $ isPunctuation 'a'
  print $ isPunctuation '7'
  print $ isPunctuation '♥'
  print $ isPunctuation '"'
  print $ isPunctuation '?'
  print $ isPunctuation '—'
  print $ isSymbol 'a'
  print $ isSymbol '6'
  print $ isSymbol '='
  print $ isSymbol '+'
  print $ isSymbol '-'
  print $ isSymbol '<'
