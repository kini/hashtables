{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP          #-}
{-# LANGUAGE MagicHash    #-}

{-|

A basic open-addressing hash table using linear probing. Use this hash table if
you...

  * want the fastest possible lookups, and very fast inserts.

  * don't care about wasting a little bit of memory to get it.

  * don't care that a table resize might pause for a long time to rehash all
    of the key-value mappings.

  * have a workload which is not heavy with deletes; deletes clutter the table
    with deleted markers and force the table to be completely rehashed fairly
    often.

Of the hash tables in this collection, this hash table has the best lookup
performance, while maintaining competitive insert performance.

/Space overhead/

This table is not especially memory-efficient; firstly, the table has a maximum
load factor of 0.83 and will be resized if load exceeds this value. Secondly,
to improve insert and lookup performance, we store a 16-bit hash code for each
key in the table.

Each hash table entry requires at least 2.25 words (on a 64-bit machine), two
for the pointers to the key and value and one quarter word for the hash code.
We don't count key and value pointers as overhead, because they have to be
there -- so the overhead for a full slot is at least one quarter word -- but
empty slots in the hash table count for a full 2.25 words of overhead. Define
@m@ as the number of slots in the table, @n@ as the number of key value
mappings, and @ws@ as the machine word size in /bytes/. If the load factor is
@k=n\/m@, the amount of space /wasted/ per mapping in words is:

@
w(n) = (m*(2*ws + 2) - n*(2*ws)) / ws
@

Since @m=n\/k@,

@
w(n) = n\/k * (2*ws + 2) - n*(2*ws)
     = (n * (2 + 2*ws*(1-k)) / k) / ws
@

Solving for @k=0.83@, the maximum load factor, gives a /minimum/ overhead of
0.71 words per mapping on a 64-bit machine, or 1.01 words per mapping on a
32-bit machine. If @k=0.5@, which should be under normal usage the /maximum/
overhead situation, then the overhead would be 2.5 words per mapping on a
64-bit machine, or 3.0 words per mapping on a 32-bit machine.

/Space overhead: experimental results/

In randomized testing on a 64-bit machine (see
@test\/compute-overhead\/ComputeOverhead.hs@ in the source distribution), mean
overhead (that is, the number of words needed to store the key-value mapping
over and above the two words necessary for the key and the value pointers) is
approximately 1.24 machine words per key-value mapping with a standard
deviation of about 0.30 words, and 1.70 words per mapping at the 95th
percentile.

/Expensive resizes/

If enough elements are inserted into the table to make it exceed the maximum
load factor, the table is resized. A resize involves a complete rehash of all
the elements in the table, which means that any given call to 'insert' might
take /O(n)/ time in the size of the table, with a large constant factor. If a
long pause waiting for the table to resize is unacceptable for your
application, you should choose the included linear hash table instead.


/References:/

  * Knuth, Donald E. /The Art of Computer Programming/, vol. 3 Sorting and
    Searching. Addison-Wesley Publishing Company, 1973.
-}

module Data.HashTable.ST.Basic
  ( HashTable
  , new
  , newSized
  , delete
  , lookup
  , insert
  , mapM_
  , foldM
  , computeOverhead
  ) where


------------------------------------------------------------------------------
import           Control.Exception                 (assert)
import           Control.Monad                     hiding (foldM, mapM_)
import           Control.Monad.ST
import           Control.Monad.ST.Unsafe
import           Data.Bits
import           Data.Hashable                     (Hashable)
import qualified Data.Hashable                     as H
import           Data.Maybe
import           Data.Monoid
import           Data.STRef
import           GHC.Exts
import           Prelude                           hiding (lookup, mapM_, read)
------------------------------------------------------------------------------
import qualified Data.HashTable.Class              as C
import           Data.HashTable.Internal.Array
import           Data.HashTable.Internal.CacheLine
import           Data.HashTable.Internal.IntArray  (Elem)
import qualified Data.HashTable.Internal.IntArray  as U
import           Data.HashTable.Internal.Utils


------------------------------------------------------------------------------
-- | An open addressing hash table using linear probing.
newtype HashTable s k v = HT (STRef s (HashTable_ s k v))

data HashTable_ s k v = HashTable
    { _size    :: {-# UNPACK #-} !Int
    , _load    :: !(U.IntArray s)  -- ^ How many entries in the table? Prefer
                                   -- unboxed vector here to STRef because I
                                   -- know it will be appropriately strict
    , _delLoad :: !(U.IntArray s)  -- ^ How many deleted entries in the table?
    , _hashes  :: !(U.IntArray s)
    , _keys    :: {-# UNPACK #-} !(MutableArray s k)
    , _values  :: {-# UNPACK #-} !(MutableArray s v)
    }


------------------------------------------------------------------------------
instance C.HashTable HashTable where
    new             = new
    newSized        = newSized
    insert          = insert
    delete          = delete
    lookup          = lookup
    foldM           = foldM
    mapM_           = mapM_
    computeOverhead = computeOverhead


------------------------------------------------------------------------------
instance Show (HashTable s k v) where
    show _ = "<HashTable>"


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:new".
new :: ST s (HashTable s k v)
new = newSized 1
{-# INLINE new #-}


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:newSized".
newSized :: Int -> ST s (HashTable s k v)
newSized n = do
    debug $ "entering: newSized " ++ show n
    let m = nextBestPrime $ ceiling (fromIntegral n / maxLoad)
    ht <- newSizedReal m
    newRef ht
{-# INLINE newSized #-}


------------------------------------------------------------------------------
newSizedReal :: Int -> ST s (HashTable_ s k v)
newSizedReal m = do
    -- make sure the hash array is a multiple of cache-line sized so we can
    -- always search a whole cache line at once
    let m' = ((m + numElemsInCacheLine - 1) `div` numElemsInCacheLine)
             * numElemsInCacheLine
    h  <- U.newArray m'
    k  <- newArray m undefined
    v  <- newArray m undefined
    ld <- U.newArray 1
    dl <- U.newArray 1
    return $! HashTable m ld dl h k v


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:delete".
delete :: (Hashable k, Eq k) =>
          (HashTable s k v)
       -> k
       -> ST s ()
delete htRef k = do
    debug $ "entered: delete: hash=" ++ show h
    ht <- readRef htRef
    _  <- delete' ht True k h
    return ()
  where
    !h = hash k
{-# INLINE delete #-}


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:lookup".
lookup :: (Eq k, Hashable k) => (HashTable s k v) -> k -> ST s (Maybe v)
lookup htRef !k = do
    ht <- readRef htRef
    lookup' ht
  where
    lookup' (HashTable sz _ _ hashes keys values) = do
        let !b = whichBucket h sz
        debug $ "lookup h=" ++ show h ++ " sz=" ++ show sz ++ " b=" ++ show b
        go b 0 sz

      where
        !h  = hash k
        !he = hashToElem h

        go !b !start !end = {-# SCC "lookup/go" #-} do
            debug $ concat [ "lookup'/go: "
                           , show b
                           , "/"
                           , show start
                           , "/"
                           , show end
                           ]
            idx <- forwardSearch2 hashes b end he emptyMarker
            debug $ "forwardSearch2 returned " ++ show idx
            if (idx < 0 || idx < start || idx >= end)
               then return Nothing
               else do
                 h0  <- U.readArray hashes idx
                 debug $ "h0 was " ++ show h0

                 if recordIsEmpty h0
                   then do
                       debug $ "record empty, returning Nothing"
                       return Nothing
                   else do
                     k' <- readArray keys idx
                     if k == k'
                       then do
                         debug $ "value found at " ++ show idx
                         v <- readArray values idx
                         return $! Just v
                       else do
                         debug $ "value not found, recursing"
                         if idx < b
                           then go (idx + 1) (idx + 1) b
                           else go (idx + 1) start end
{-# INLINE lookup #-}


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:insert".
insert :: (Eq k, Hashable k) =>
          (HashTable s k v)
       -> k
       -> v
       -> ST s ()
insert htRef !k !v = do
    ht <- readRef htRef
    !ht' <- insert' ht
    writeRef htRef ht'

  where
    insert' ht = do
        debug "insert': calling delete'"
        b <- delete' ht False k h

        debug $ concat [ "insert': writing h="
                       , show h
                       , " he="
                       , show he
                       , " b="
                       , show b
                       ]
        U.writeArray hashes b he
        writeArray keys b k
        writeArray values b v

        checkOverflow ht

      where
        !h     = hash k
        !he    = hashToElem h
        hashes = _hashes ht
        keys   = _keys ht
        values = _values ht
{-# INLINE insert #-}


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:foldM".
foldM :: (a -> (k,v) -> ST s a) -> a -> HashTable s k v -> ST s a
foldM f seed0 htRef = readRef htRef >>= work
  where
    work (HashTable sz _ _ hashes keys values) = go 0 seed0
      where
        go !i !seed | i >= sz = return seed
                    | otherwise = do
            h <- U.readArray hashes i
            if recordIsEmpty h || recordIsDeleted h
              then go (i+1) seed
              else do
                k <- readArray keys i
                v <- readArray values i
                !seed' <- f seed (k, v)
                go (i+1) seed'


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:mapM_".
mapM_ :: ((k,v) -> ST s b) -> HashTable s k v -> ST s ()
mapM_ f htRef = readRef htRef >>= work
  where
    work (HashTable sz _ _ hashes keys values) = go 0
      where
        go !i | i >= sz = return ()
              | otherwise = do
            h <- U.readArray hashes i
            if recordIsEmpty h || recordIsDeleted h
              then go (i+1)
              else do
                k <- readArray keys i
                v <- readArray values i
                _ <- f (k, v)
                go (i+1)


------------------------------------------------------------------------------
-- | See the documentation for this function in
-- "Data.HashTable.Class#v:computeOverhead".
computeOverhead :: HashTable s k v -> ST s Double
computeOverhead htRef = readRef htRef >>= work
  where
    work (HashTable sz' loadRef _ _ _ _) = do
        !ld <- U.readArray loadRef 0
        let k = fromIntegral ld / sz
        return $ constOverhead/sz + (2 + 2*ws*(1-k)) / (k * ws)
      where
        ws = fromIntegral $! bitSize (0::Int) `div` 8
        sz = fromIntegral sz'
        -- Change these if you change the representation
        constOverhead = 14


------------------------------
-- Private functions follow --
------------------------------


------------------------------------------------------------------------------
{-# INLINE insertRecord #-}
insertRecord :: Int
             -> U.IntArray s
             -> MutableArray s k
             -> MutableArray s v
             -> Int
             -> k
             -> v
             -> ST s ()
insertRecord !sz !hashes !keys !values !h !key !value = do
    let !b = whichBucket h sz
    debug $ "insertRecord sz=" ++ show sz ++ " h=" ++ show h ++ " b=" ++ show b
    probe b

  where
    he = hashToElem h

    probe !i = {-# SCC "insertRecord/probe" #-} do
        !idx <- forwardSearch2 hashes i sz emptyMarker deletedMarker
        debug $ "forwardSearch2 returned " ++ show idx
        assert (idx >= 0) $ do
            U.writeArray hashes idx he
            writeArray keys idx key
            writeArray values idx value


------------------------------------------------------------------------------
checkOverflow :: (Eq k, Hashable k) =>
                 (HashTable_ s k v)
              -> ST s (HashTable_ s k v)
checkOverflow ht@(HashTable sz ldRef delRef _ _ _) = do
    !ld <- U.readArray ldRef 0
    let !ld' = ld + 1
    U.writeArray ldRef 0 ld'
    !dl <- U.readArray delRef 0

    debug $ concat [ "checkOverflow: sz="
                   , show sz
                   , " entries="
                   , show ld
                   , " deleted="
                   , show dl ]

    if fromIntegral (ld + dl) / fromIntegral sz > maxLoad
      then if dl > ld `div` 2
             then rehashAll ht sz
             else growTable ht
      else return ht


------------------------------------------------------------------------------
rehashAll :: Hashable k => HashTable_ s k v -> Int -> ST s (HashTable_ s k v)
rehashAll (HashTable sz loadRef _ hashes keys values) sz' = do
    debug $ "rehashing: old size " ++ show sz ++ ", new size " ++ show sz'
    ht' <- newSizedReal sz'
    let (HashTable _ loadRef' _ newHashes newKeys newValues) = ht'
    U.readArray loadRef 0 >>= U.writeArray loadRef' 0
    rehash newHashes newKeys newValues
    return ht'

  where
    rehash newHashes newKeys newValues = go 0
      where
        go !i | i >= sz   = return ()
              | otherwise = {-# SCC "growTable/rehash" #-} do
                    h0 <- U.readArray hashes i
                    when (not (recordIsEmpty h0 || recordIsDeleted h0)) $ do
                        k <- readArray keys i
                        v <- readArray values i
                        insertRecord sz' newHashes newKeys newValues
                                     (hash k) k v
                    go $ i+1


------------------------------------------------------------------------------
growTable :: Hashable k => HashTable_ s k v -> ST s (HashTable_ s k v)
growTable ht@(HashTable sz _ _ _ _ _) = do
    let !sz' = bumpSize maxLoad sz
    rehashAll ht sz'


------------------------------------------------------------------------------
-- Helper data structure for delete'
data Slot = Slot {
      _slot       :: {-# UNPACK #-} !Int
    , _wasDeleted :: {-# UNPACK #-} !Int  -- we use Int because Bool won't
                                          -- unpack
    }
  deriving (Show)


------------------------------------------------------------------------------
instance Monoid Slot where
    mempty = Slot maxBound 0
    (Slot x1 b1) `mappend` (Slot x2 b2) =
        if x1 == maxBound then Slot x2 b2 else Slot x1 b1


------------------------------------------------------------------------------
-- Returns the slot in the array where it would be safe to write the given key.
delete' :: (Hashable k, Eq k) =>
           (HashTable_ s k v)
        -> Bool
        -> k
        -> Int
        -> ST s Int
delete' (HashTable sz loadRef delRef hashes keys values) clearOut k h = do
    debug $ "delete': h=" ++ show h ++ " he=" ++ show he
            ++ " sz=" ++ show sz ++ " b0=" ++ show b0
    pair@(found, slot) <- go mempty b0 False
    debug $ "go returned " ++ show pair

    let !b' = _slot slot

    when found $ bump loadRef (-1)

    -- bump the delRef lower if we're writing over a deleted marker
    when (not clearOut && _wasDeleted slot == 1) $ bump delRef (-1)
    return b'

  where
    he = hashToElem h
    bump ref i = do
        !ld <- U.readArray ref 0
        U.writeArray ref 0 $! ld + i

    !b0 = whichBucket h sz

    haveWrapped !(Slot fp _) !b = if fp == maxBound
                                    then False
                                    else b <= fp

    -- arguments:

    --   * fp    maintains the slot in the array where it would be safe to
    --           write the given key
    --   * b     search the buckets array starting at this index.
    --   * wrap  True if we've wrapped around, False otherwise

    go !fp !b !wrap = do
        debug $ concat [ "go: fp="
                       , show fp
                       , " b="
                       , show b
                       , ", wrap="
                       , show wrap
                       , ", he="
                       , show he
                       , ", emptyMarker="
                       , show emptyMarker
                       , ", deletedMarker="
                       , show deletedMarker ]

        !idx <- forwardSearch3 hashes b sz he emptyMarker deletedMarker
        debug $ "forwardSearch3 returned " ++ show idx ++ " with sz=" ++ show sz ++ ", b=" ++ show b

        if wrap && idx >= b0
          -- we wrapped around in the search and didn't find our hash code;
          -- this means that the table is full of deleted elements. Just return
          -- the first place we'd be allowed to insert.
          --
          -- TODO: if we get in this situation we should probably just rehash
          -- the table, because every insert is going to be O(n).
          then return $!
                   (False, fp `mappend` (Slot (error "impossible") 0))
          else do
            -- because the table isn't full, we know that there must be either
            -- an empty or a deleted marker somewhere in the table. Assert this
            -- here.
            assert (idx >= 0) $ return ()
            h0 <- U.readArray hashes idx
            debug $ "h0 was " ++ show h0

            if recordIsEmpty h0
              then do
                  let pl = fp `mappend` (Slot idx 0)
                  debug $ "empty, returning " ++ show pl
                  return (False, pl)
              else do
                let !wrap' = haveWrapped fp idx
                if recordIsDeleted h0
                  then do
                      let pl = fp `mappend` (Slot idx 1)
                      debug $ "deleted, cont with pl=" ++ show pl
                      go pl (idx + 1) wrap'
                  else
                    if he == h0
                      then do
                        debug $ "found he == h0 == " ++ show h0
                        k' <- readArray keys idx
                        if k == k'
                          then do
                            let samePlace = _slot fp == idx
                            debug $ "found at " ++ show idx
                            debug $ "clearout=" ++ show clearOut
                            debug $ "sp? " ++ show samePlace
                            -- "clearOut" is set if we intend to write a new
                            -- element into the slot. If we're doing an update
                            -- and we found the old key, instead of writing
                            -- "deleted" and then re-writing the new element
                            -- there, we can just write the new element. This
                            -- only works if we were planning on writing the
                            -- new element here.
                            when (clearOut || not samePlace) $ do
                                bump delRef 1
                                U.writeArray hashes idx deletedMarker
                                writeArray keys idx undefined
                                writeArray values idx undefined
                            return (True, fp `mappend` (Slot idx 0))
                          else go fp (idx + 1) wrap'
                      else go fp (idx + 1) wrap'

------------------------------------------------------------------------------
maxLoad :: Double
maxLoad = 0.82


------------------------------------------------------------------------------
emptyMarker :: Elem
emptyMarker = 0

------------------------------------------------------------------------------
deletedMarker :: Elem
deletedMarker = 1


------------------------------------------------------------------------------
{-# INLINE recordIsEmpty #-}
recordIsEmpty :: Elem -> Bool
recordIsEmpty = (== emptyMarker)


------------------------------------------------------------------------------
{-# INLINE recordIsDeleted #-}
recordIsDeleted :: Elem -> Bool
recordIsDeleted = (== deletedMarker)


------------------------------------------------------------------------------
{-# INLINE hash #-}
hash :: (Hashable k) => k -> Int
hash = H.hash


------------------------------------------------------------------------------
{-# INLINE hashToElem #-}
hashToElem :: Int -> Elem
hashToElem !h = out
  where
    !(I# lo#) = h .&. U.elemMask

    !m#  = maskw# lo# 0# `or#` maskw# lo# 1#
    !nm# = not# m#

    !r#  = ((int2Word# 2#) `and#` m#) `or#` (int2Word# lo# `and#` nm#)
    !out = U.primWordToElem r#


------------------------------------------------------------------------------
newRef :: HashTable_ s k v -> ST s (HashTable s k v)
newRef = liftM HT . newSTRef
{-# INLINE newRef #-}

writeRef :: HashTable s k v -> HashTable_ s k v -> ST s ()
writeRef (HT ref) ht = writeSTRef ref ht
{-# INLINE writeRef #-}

readRef :: HashTable s k v -> ST s (HashTable_ s k v)
readRef (HT ref) = readSTRef ref
{-# INLINE readRef #-}


------------------------------------------------------------------------------
{-# INLINE debug #-}
debug :: String -> ST s ()
#ifdef DEBUG
debug s = unsafeIOToST (putStrLn s)
#else
debug _ = return ()
#endif
